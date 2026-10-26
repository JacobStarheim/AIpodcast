package io.github.jacobstarheim.aipodcast

import com.ryanheise.audioservice.AudioServiceActivity

// Shares its Flutter engine with the background playback service
// (audio_service), so lock screen controls reach the running app.
class MainActivity : AudioServiceActivity()
