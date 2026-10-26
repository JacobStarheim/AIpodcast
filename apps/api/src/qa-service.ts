import type { Citation, EpisodeDetail, QAResponse, QATurn } from "@podcast/shared-types";
import { fuseRankings, searchTerms } from "./retrieval.js";
import { HttpError } from "./security.js";
import type { AIClient, Evidence, Repository, RetrievedSegment, SearchPlan } from "./types.js";

export interface QaDependencies {
  repository: Repository;
  aiClient: AIClient;
  minGroundingScore: number;
  logError?: (message: string, error: unknown) => void;
}

export interface QaInput {
  questionText: string;
  episodeId?: string;
  positionSec?: number;
  history: QATurn[];
  topK: number;
}

const refusalText = "I do not have enough transcript evidence to answer that confidently.";
/** How much audio before the playback position counts as "just heard". */
const RECENT_WINDOW_SEC = 90;
/** Similarity above the grounding threshold at which the search plan is skipped. */
const CONFIDENT_MARGIN = 0.15;

function chapterEvidence(episode: EpisodeDetail): Evidence[] {
  return episode.chapters.map((chapter) => ({
    segmentId: `chapter:${chapter.id}`,
    kind: "chapter",
    episodeId: episode.id,
    episodeTitle: episode.title,
    startSec: chapter.startSec,
    endSec: chapter.endSec,
    text: `${chapter.title}: ${chapter.summary}`,
    score: 0
  }));
}

/** A keyword hit counts as evidence when it contains most of the distinctive terms. */
function strongKeywordMatch(hits: RetrievedSegment[], terms: string[]): boolean {
  const best = hits[0];
  if (!best || terms.length === 0) return false;
  const text = best.text.toLocaleLowerCase();
  const found = terms.filter((term) => text.includes(term)).length;
  return found >= Math.min(terms.length, Math.max(2, Math.ceil(terms.length / 2)));
}

function toCitation(evidence: Evidence): Citation {
  const { recentlyHeard: _recentlyHeard, ...citation } = evidence;
  return citation;
}

export async function answerQuestion(deps: QaDependencies, input: QaInput): Promise<QAResponse> {
  const startedAt = Date.now();
  const { repository, aiClient } = deps;
  const logError = deps.logError ?? console.error;

  let episode: EpisodeDetail | null = null;
  if (input.episodeId) {
    episode = await repository.getEpisodeById(input.episodeId);
    if (!episode) throw new HttpError(404, "not_found");
    if (episode.transcriptionStatus !== "ready") {
      throw new HttpError(409, "episode is not ready for questions");
    }
  }

  const finish = async (response: QAResponse): Promise<QAResponse> => {
    await repository.logQaEvent({
      episodeId: input.episodeId,
      questionText: input.questionText,
      grounded: response.grounded,
      latencyMs: Date.now() - startedAt
    });
    return response;
  };
  const refuse = (refusalReason: string) =>
    finish({ answerText: refusalText, citations: [], grounded: false, refusalReason });

  // Rewrite follow-ups into standalone queries and translate them into the
  // transcript language, so "what did he mean?" or a Norwegian question about
  // an English episode still finds the right passages. Planning is the
  // slowest step, so it runs while the question as asked is searched.
  const planAbort = new AbortController();
  const planned: Promise<SearchPlan> = (async () => aiClient.planSearch({
    questionText: input.questionText,
    history: input.history,
    transcriptLanguages: episode
      ? [episode.language].filter((language): language is string => Boolean(language))
      : await repository.listReadyLanguages(),
    episodeTitle: episode?.title ?? null,
    signal: planAbort.signal
  }))().catch((error: unknown) => {
    if (!planAbort.signal.aborted) {
      logError("Search planning failed; searching with the question as asked", error);
    }
    return { queries: [], overview: false };
  });

  const perQuery = Math.max(input.topK, 8);
  const [questionEmbedding = []] = await aiClient.embedTexts([input.questionText]);
  const questionHits = await repository.searchSegments({
    embedding: questionEmbedding, episodeId: input.episodeId, topK: perQuery
  });

  // A first question that already matches a passage well needs neither
  // rewriting nor translation; answer without waiting for the plan.
  const confident = input.history.length === 0 &&
    Math.max(0, ...questionHits.map((segment) => segment.score)) >= deps.minGroundingScore + CONFIDENT_MARGIN;
  let plan: SearchPlan = { queries: [], overview: false };
  if (confident) {
    planAbort.abort();
  } else {
    plan = await planned;
  }

  const extraQueries = [...new Set(plan.queries.map((query) => query.trim()).filter(Boolean))]
    .filter((query) => query !== input.questionText)
    .slice(0, 3);
  const extraEmbeddings = extraQueries.length > 0 ? await aiClient.embedTexts(extraQueries) : [];
  const vectorLists = [
    questionHits,
    ...(await Promise.all(extraEmbeddings.map((embedding) =>
      repository.searchSegments({ embedding, episodeId: input.episodeId, topK: perQuery }))))
  ];
  const queries = [input.questionText, ...extraQueries];
  const terms = searchTerms(queries);
  const keywordHits = await repository.searchSegmentsByText({ terms, episodeId: input.episodeId, topK: perQuery });
  const retrieved = fuseRankings([...vectorLists, keywordHits], input.topK);
  const topVectorScore = Math.max(0, ...vectorLists.flat().map((segment) => segment.score));

  const recentlyHeard: Evidence[] = episode && input.positionSec !== undefined
    ? (await repository.segmentsBetween({
        episodeId: episode.id,
        fromSec: Math.max(0, input.positionSec - RECENT_WINDOW_SEC),
        toSec: input.positionSec + 5,
        limit: 6
      })).map((segment) => ({ ...segment, recentlyHeard: true }))
    : [];
  const chapters: Evidence[] = episode
    ? chapterEvidence(episode)
    : await repository.searchChapters({ embedding: questionEmbedding, topK: 3 });

  const hasEvidence =
    topVectorScore >= deps.minGroundingScore ||
    strongKeywordMatch(keywordHits, terms) ||
    recentlyHeard.length > 0 ||
    (plan.overview && (chapters.length > 0 || Boolean(episode?.summary)));
  if (!hasEvidence) {
    return refuse("insufficient_retrieval_confidence");
  }

  // Passages are embedded together with their neighbours, so a hit often
  // means "the answer is here or right next to it". Give the model both.
  const heardIds = new Set(recentlyHeard.map((segment) => segment.segmentId));
  const evidence: Evidence[] = [
    ...recentlyHeard,
    ...(await repository.withNeighbours(retrieved)).filter((segment) => !heardIds.has(segment.segmentId)),
    ...chapters.slice(0, 24)
  ];

  const answer = await aiClient.answerGrounded({
    questionText: input.questionText,
    evidence,
    history: input.history,
    episodeSummary: episode?.summary ?? null
  });
  const citations = [...new Set(answer.citationIndices)]
    .filter((index) => Number.isInteger(index) && index >= 0 && index < evidence.length)
    .map((index) => toCitation(evidence[index]!));

  if (!answer.answerText.trim() || citations.length === 0) {
    return refuse("insufficient_grounded_citations");
  }
  return finish({ answerText: answer.answerText.trim(), citations, grounded: true });
}
