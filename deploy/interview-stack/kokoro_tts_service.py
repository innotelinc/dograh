"""
Kokoro HTTP TTS service for dograh (reference file).

WHY THIS EXISTS
───────────────
Pipecat's built-in `KokoroTTSService` (`pipecat.services.kokoro.tts`) runs the
kokoro-onnx model IN-PROCESS — it takes ONNX model file paths, downloads model
files on first use, and never talks to an HTTP server. It cannot be pointed at
the `kokoro-fastapi` container URL.

The container exposes an OpenAI-compatible `POST /v1/audio/speech`, so the right
pipecat class is `OpenAITTSService` with a custom `base_url`. The one blocker:
`OpenAITTSService.run_tts` validates `voice` against a hardcoded list of OpenAI
voice names (`VALID_VOICES` = alloy, ash, ballad, ...) and rejects Kokoro voices
like `af_heart` before the request is even sent.

This subclass removes that gate and passes the voice name straight through.

INSTALL
───────
Copy to:  api/services/pipecat/kokoro_tts.py   (next to minimax_tts.py)

Then in api/services/pipecat/service_factory.py:

  1. Add the import (alphabetize next to the other pipecat imports):
         from api.services.pipecat.kokoro_tts import KokoroHttpTTSService

  2. In `create_tts_service`, change the OPENAI branch to use the subclass:

         elif user_config.tts.provider == ServiceProviders.OPENAI.value:
             kwargs = {}
             base_url = getattr(user_config.tts, "base_url", None)
             if base_url:
                 _validate_runtime_service_url(base_url, "base_url")
                 kwargs["base_url"] = base_url
             return KokoroHttpTTSService(          # was: OpenAITTSService
                 api_key=user_config.tts.api_key,
                 sample_rate=OPENAI_SAMPLE_RATE,
                 settings=OpenAITTSSettings(model=user_config.tts.model),
                 text_filters=[xml_function_tag_filter],
                 skip_aggregator_types=["recording_router", "recording"],
                 silence_time_s=1.0,
                 **kwargs,
             )

DOGRAH UI CONFIG (TTS section)
──────────────────────────────
  provider   : OpenAI
  model      : kokoro            (any string; kokoro-fastapi ignores it)
  voice      : af_heart          (any Kokoro voice: af_heart, am_michael, ...)
  base_url   : http://127.0.0.1:8880/v1   (dograh runs in host mode)
  api_key    : anything          (kokoro-fastapi doesn't check it)
"""

from pipecat.services.openai.tts import OpenAITTSService


class KokoroHttpTTSService(OpenAITTSService):
    """OpenAI-compatible TTS pointed at a local kokoro-fastapi server.

    Same as OpenAITTSService but skips the hardcoded OpenAI-only voice allowlist
    so Kokoro voice names (``af_heart``, ``am_michael``, ...) are sent verbatim.
    """

    async def run_tts(self, text: str, context_id: str):
        # Import frames lazily to keep the module import-light.
        from pipecat.frames.frames import ErrorFrame, TTSAudioRawFrame

        voice = self._settings.voice
        if not voice:
            yield ErrorFrame(error="Kokoro TTS voice must be specified")
            return

        try:
            # Same request shape as the parent, but the voice name is passed
            # through unchanged and "pcm" is requested (kokoro-fastapi supports
            # pcm, wav, mp3, flac, ...).
            create_params = {
                "input": text,
                "model": self._settings.model,
                "voice": voice,
                "response_format": "pcm",
            }
            if self._settings.speed:
                create_params["speed"] = self._settings.speed

            async with self._client.audio.speech.with_streaming_response.create(
                **create_params
            ) as r:
                if r.status_code != 200:
                    error = await r.text()
                    yield ErrorFrame(
                        error=f"Kokoro TTS error (status: {r.status_code}, error: {error})"
                    )
                    return

                await self.start_tts_usage_metrics(text)

                async for chunk in r.iter_bytes(self.chunk_size):
                    if len(chunk) > 0:
                        await self.stop_ttfb_metrics()
                        yield TTSAudioRawFrame(
                            chunk, self.sample_rate, 1, context_id=context_id
                        )
        except Exception as e:
            yield ErrorFrame(error=f"Unknown Kokoro TTS error: {e}")
        finally:
            await self.stop_ttfb_metrics()
