package br.com.sabordochef.impressao

import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Supabase Realtime public Broadcast listener.
 * Payload contains no order, customer, device or job identifiers.
 * The event is only a wake-up signal; the authenticated device API remains
 * the sole source of truth for claiming and acknowledging print jobs.
 */
class RealtimePrintListener(
    private val onSignal: () -> Unit
) {
    private val monitor = Object()
    // Latch a wake-up that arrives between the queue check and awaitSignal().
    private var signalPending = false
    @Volatile private var active = false
    @Volatile var isConnected: Boolean = false
        private set
    @Volatile private var socket: WebSocket? = null
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(25, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    fun connect() {
        if (active) return
        active = true
        thread(name = "sabor-realtime-connect") { reconnectLoop() }
    }

    /**
     * Wait for a Realtime wake-up, but never block forever.
     * The pending latch closes the check-to-wait race; the timeout is a safety
     * net for dropped broadcasts or a socket that appears connected but is stale.
     * On timeout, the worker checks the authenticated queue again.
     */
    fun awaitSignal(timeoutMs: Long = 30_000L): Boolean {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        synchronized(monitor) {
            while (active && !signalPending) {
                val remainingNanos = deadline - System.nanoTime()
                if (remainingNanos <= 0L) break
                val waitMs = TimeUnit.NANOSECONDS.toMillis(remainingNanos).coerceAtLeast(1L)
                monitor.wait(waitMs)
            }
            val received = signalPending
            signalPending = false
            return received
        }
    }

    private fun signal() {
        synchronized(monitor) {
            signalPending = true
            monitor.notifyAll()
        }
        try { onSignal() } catch (_: Exception) { }
    }

    private fun reconnectLoop() {
        var delayMs = 1000L
        while (active) {
            var heartbeat: Thread? = null
            try {
                val request = Request.Builder()
                    .url("$REALTIME_URL?apikey=$PUBLISHABLE_KEY&vsn=1.0.0")
                    .build()
                val joined = java.util.concurrent.CountDownLatch(1)
                val closed = java.util.concurrent.CountDownLatch(1)
                val joinOk = java.util.concurrent.atomic.AtomicBoolean(false)
                val ws = client.newWebSocket(request, object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        socket = webSocket
                        val join = JSONObject()
                            .put("topic", TOPIC)
                            .put("event", "phx_join")
                            .put("payload", JSONObject().put("config",
                                JSONObject()
                                    .put("broadcast", JSONObject().put("ack", false).put("self", false))
                                    .put("presence", JSONObject().put("key", ""))
                                    .put("postgres_changes", org.json.JSONArray())
                                    .put("private", false)
                            ))
                            .put("ref", "1")
                        webSocket.send(join.toString())
                    }

                    override fun onMessage(webSocket: WebSocket, text: String) {
                        try {
                            val message = JSONObject(text)
                            when (message.optString("event")) {
                                "phx_reply" -> {
                                    val status = message.optJSONObject("payload")?.optString("status")
                                    if (status == "ok" && !joinOk.getAndSet(true)) {
                                        joined.countDown()
                                        isConnected = true
                                        Log.i(TAG, "Supabase Realtime conectado")
                                        delayMs = 1000L
                                        signal()
                                    } else if (status == "error") closed.countDown()
                                }
                                "broadcast" -> {
                                    val payload = message.optJSONObject("payload")
                                    if (payload?.optString("event") == "queue_changed") {
                                        Log.i(TAG, "Evento Realtime: fila de impressão atualizada")
                                        signal()
                                    }
                                }
                                "phx_error", "phx_close" -> closed.countDown()
                            }
                        } catch (_: Exception) { }
                    }

                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                        isConnected = false
                        Log.w(TAG, "WebSocket Realtime desconectado: ${t.message}")
                        signal()
                        joined.countDown()
                        closed.countDown()
                    }

                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                        isConnected = false
                        signal()
                        joined.countDown()
                        closed.countDown()
                    }
                })
                socket = ws

                if (!joined.await(20, TimeUnit.SECONDS) || !joinOk.get()) {
                    ws.cancel()
                    closed.countDown()
                } else {
                    heartbeat = thread(name = "sabor-realtime-heartbeat") {
                        var ref = 2
                        while (active && closed.count > 0) {
                            try { Thread.sleep(25000) } catch (_: InterruptedException) { break }
                            val current = socket ?: break
                            val frame = JSONObject()
                                .put("topic", "phoenix")
                                .put("event", "heartbeat")
                                .put("payload", JSONObject())
                                .put("ref", (ref++).toString())
                            if (!current.send(frame.toString())) break
                        }
                    }
                    closed.await()
                }
                try { ws.close(1000, "reconnect") } catch (_: Exception) { }
            } catch (_: InterruptedException) {
                break
            } catch (_: Exception) {
                // No database polling fallback: reconnect logic restores the Realtime channel.
            } finally {
                try { heartbeat?.interrupt() } catch (_: Exception) { }
                socket = null
                isConnected = false
                signal()
                delayMs = (delayMs * 2).coerceAtMost(60000L)
            }
            if (active) try { Thread.sleep(delayMs) } catch (_: InterruptedException) { break }
        }
    }

    fun close() {
        active = false
        isConnected = false
        synchronized(monitor) { monitor.notifyAll() }
        try { socket?.close(1000, "service stopped") } catch (_: Exception) { }
        socket = null
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
    }

    companion object {
        private const val TAG = "SaborChefRealtime"
        private const val REALTIME_URL = "wss://enakuleybfvzqurrttwl.supabase.co/realtime/v1/websocket"
        private const val PUBLISHABLE_KEY = "sb_publishable_JnYedcVNm6Q2tao49qaYzQ_qxjelyqA"
        private const val TOPIC = "realtime:printer-queue"
    }
}
