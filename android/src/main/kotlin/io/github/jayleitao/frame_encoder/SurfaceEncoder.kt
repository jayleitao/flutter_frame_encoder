package io.github.jayleitao.frame_encoder

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer

/**
 * Writes H.264 MP4 from RGBA frames with MediaCodec. Each frame is drawn on
 * the encoder's input Surface with a hardware Canvas. Surface timestamps
 * follow the wall clock, so the muxer is given exact presentation times
 * (frame index / fps) instead; MediaCodec's AVC encoders emit frames in
 * input order (no B-frames by default), which keeps that mapping correct.
 *
 * Not thread safe: use one thread per encoder.
 */
class SurfaceEncoder(
  private val width: Int,
  private val height: Int,
  private val fps: Int,
  bitrate: Int,
  private val outputPath: String,
) {
  private val codec: MediaCodec
  private val surface: Surface
  private val muxer: MediaMuxer
  private val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
  private val info = MediaCodec.BufferInfo()
  private var track = -1
  private var muxerStarted = false
  private var framesIn = 0L
  private var framesOut = 0L

  init {
    File(outputPath).delete()
    val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
      setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
      setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
      setInteger(MediaFormat.KEY_FRAME_RATE, fps)
      setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
    }
    codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
    surface = codec.createInputSurface()
    codec.start()
    muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
  }

  /** [rgba] is width * height * 4 bytes; Android's ARGB_8888 is RGBA in memory. */
  fun addFrame(rgba: ByteArray, repeat: Int) {
    require(rgba.size == width * height * 4) { "wrong frame size" }
    bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
    repeat(repeat) {
      val canvas = surface.lockHardwareCanvas()
      try {
        canvas.drawBitmap(bitmap, 0f, 0f, null)
      } finally {
        surface.unlockCanvasAndPost(canvas)
      }
      framesIn++
      drain(endOfStream = false)
    }
  }

  /** Returns the output path. */
  fun finish(audioPath: String?): String {
    codec.signalEndOfInputStream()
    drain(endOfStream = true)
    release()
    if (audioPath != null) AudioMuxer.mux(outputPath, audioPath, framesIn * 1_000_000L / fps)
    return outputPath
  }

  fun cancel() {
    try {
      release()
    } catch (_: Exception) {
    }
    File(outputPath).delete()
  }

  private fun release() {
    try { codec.stop() } catch (_: Exception) {}
    codec.release()
    surface.release()
    if (muxerStarted) muxer.stop()
    muxer.release()
    bitmap.recycle()
  }

  private fun drain(endOfStream: Boolean) {
    var waits = 0
    while (true) {
      val index = codec.dequeueOutputBuffer(info, if (endOfStream) 10_000 else 0)
      when {
        index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
          // Mid-stream, wait briefly for the encoder to catch up (so input
          // buffers do not run out), but never block: some encoders hold a
          // few frames of lookahead until more input arrives.
          if (!endOfStream) {
            if (framesOut >= framesIn - MAX_IN_FLIGHT || ++waits > 50) return
            Thread.sleep(2)
          }
        }
        index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
          check(!muxerStarted) { "format changed twice" }
          track = muxer.addTrack(codec.outputFormat)
          muxer.start()
          muxerStarted = true
        }
        index >= 0 -> {
          val buffer = codec.getOutputBuffer(index)!!
          if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
          if (info.size > 0 && muxerStarted) {
            buffer.position(info.offset)
            buffer.limit(info.offset + info.size)
            info.presentationTimeUs = framesOut * 1_000_000L / fps
            muxer.writeSampleData(track, buffer, info)
            framesOut++
          }
          codec.releaseOutputBuffer(index, false)
          if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
        }
      }
    }
  }

  private companion object {
    const val MAX_IN_FLIGHT = 4
  }
}

/** Adds an audio track to a finished MP4, trimmed to the video length, without re-encoding. */
internal object AudioMuxer {
  fun mux(videoPath: String, audioPath: String, durationUs: Long) {
    val temp = File("$videoPath.tmp.mp4")
    val muxer = MediaMuxer(temp.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    val video = MediaExtractor().apply { setDataSource(videoPath) }
    val audio = MediaExtractor().apply { setDataSource(audioPath) }
    try {
      val vIndex = firstTrack(video, "video/") ?: error("no video track")
      val aIndex = firstTrack(audio, "audio/") ?: error("no audio track in $audioPath")
      video.selectTrack(vIndex)
      audio.selectTrack(aIndex)
      val vTrack = muxer.addTrack(video.getTrackFormat(vIndex))
      val aTrack = muxer.addTrack(audio.getTrackFormat(aIndex))
      muxer.start()
      val buffer = ByteBuffer.allocate(4 * 1024 * 1024)
      copy(video, muxer, vTrack, buffer, Long.MAX_VALUE)
      copy(audio, muxer, aTrack, buffer, durationUs)
      muxer.stop()
    } finally {
      muxer.release()
      video.release()
      audio.release()
    }
    check(temp.renameTo(File(videoPath))) { "could not replace $videoPath" }
  }

  private fun firstTrack(extractor: MediaExtractor, prefix: String): Int? =
    (0 until extractor.trackCount).firstOrNull {
      extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith(prefix) == true
    }

  private fun copy(
    extractor: MediaExtractor,
    muxer: MediaMuxer,
    track: Int,
    buffer: ByteBuffer,
    untilUs: Long,
  ) {
    val info = MediaCodec.BufferInfo()
    while (true) {
      buffer.clear()
      val size = extractor.readSampleData(buffer, 0)
      if (size < 0 || extractor.sampleTime >= untilUs) return
      info.set(0, size, extractor.sampleTime, extractor.sampleFlags)
      muxer.writeSampleData(track, buffer, info)
      extractor.advance()
    }
  }
}
