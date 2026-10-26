/**
 * Like Promise.all over items.map(fn), but with at most `limit` calls in
 * flight. Results keep the input order. After the first failure no new calls
 * start, and the first error is thrown once running calls have settled.
 */
export async function mapWithConcurrency<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  let failure: { error: unknown } | null = null;

  async function run(): Promise<void> {
    while (!failure && next < items.length) {
      const index = next;
      next += 1;
      try {
        results[index] = await fn(items[index] as T, index);
      } catch (error) {
        failure ??= { error };
      }
    }
  }

  await Promise.all(Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, run));
  if (failure) throw (failure as { error: unknown }).error;
  return results;
}
