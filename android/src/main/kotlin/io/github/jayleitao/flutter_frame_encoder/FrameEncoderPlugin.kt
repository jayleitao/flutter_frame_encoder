package io.github.jayleitao.flutter_frame_encoder

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class FrameEncoderPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel
  private val sessions = ConcurrentHashMap<Int, Session>()
  private val nextId = AtomicInteger(1)
  private val main = Handler(Looper.getMainLooper())

  /** Each session has its own thread, so frames stay in order. */
  private class Session(val encoder: SurfaceEncoder, val executor: ExecutorService)

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "io.github.jayleitao/flutter_frame_encoder")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    for ((_, s) in sessions) {
      s.executor.execute { s.encoder.cancel() }
      s.executor.shutdown()
    }
    sessions.clear()
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "start" -> {
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        val fps = call.argument<Int>("fps")
        val bitrate = call.argument<Int>("bitrate")
        val path = call.argument<String>("outputPath")
        if (width == null || height == null || fps == null || bitrate == null || path == null) {
          return result.error("args", "missing or invalid arguments", null)
        }
        val executor = Executors.newSingleThreadExecutor()
        executor.execute {
          try {
            val encoder = SurfaceEncoder(width, height, fps, bitrate, path)
            val id = nextId.getAndIncrement()
            sessions[id] = Session(encoder, executor)
            main.post { result.success(id) }
          } catch (e: Exception) {
            executor.shutdown()
            main.post { result.error("start", e.toString(), null) }
          }
        }
      }
      "addFrame" -> {
        val session = session(call) ?: return result.error("args", "unknown session", null)
        val rgba = call.argument<ByteArray>("rgba")
          ?: return result.error("args", "missing rgba", null)
        val repeat = call.argument<Int>("repeat") ?: 1
        run(session, result, "frame") { session.encoder.addFrame(rgba, repeat); null }
      }
      "finish" -> {
        val id = call.argument<Int>("id")
        val session = id?.let { sessions.remove(it) }
          ?: return result.error("args", "unknown session", null)
        val audio = call.argument<String>("audioPath")
        run(session, result, "finish") { session.encoder.finish(audio) }
        session.executor.shutdown()
      }
      "cancel" -> {
        val id = call.argument<Int>("id")
        val session = id?.let { sessions.remove(it) } ?: return result.success(null)
        session.executor.execute { session.encoder.cancel() }
        session.executor.shutdown()
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  private fun session(call: MethodCall): Session? =
    call.argument<Int>("id")?.let { sessions[it] }

  private fun run(
    session: Session,
    result: MethodChannel.Result,
    code: String,
    work: () -> Any?,
  ) {
    session.executor.execute {
      try {
        val value = work()
        main.post { result.success(value) }
      } catch (e: Exception) {
        main.post { result.error(code, e.toString(), null) }
      }
    }
  }
}
