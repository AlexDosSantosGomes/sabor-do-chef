package br.com.sabordochef.impressao

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
    @Volatile private var active = false
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

    fun awaitSignal(timeoutMs: Long) {
        synchronized(monitor) {
            if (active) monitor.wait(timeoutMs)
        }
    }

    private fun signal() {
        synchronized(monitor) { monitor.notifyAll() }
        try { onSignal() } catch (_: Exception) { }
    }

    private fun reconnectLoop() {
        var delayMs = 1000L
        while (active) {
            try {
                val request = Request.Builder()
                    .url("$REALTIME_URL?apikey=$PUBLISHABLE_KEY&vsn=1.0.0")
                    .build()
                val latch = java.util.concurrent.CountDownLatch(1)
                val connected = java.util.concurrent.atomic.AtomicBoolean(false)
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
                            if (message.optString("event") == "phx_reply") {
                                val status = message.optJSONObject("payload")?.optString("status")
                                if (status == "ok" && !connected.getAndSet(true)) {
                                    delayMs = 1000L
                                    signal() // reconcile queue immediately after every reconnect
                                    latch.countDown()
                                }
                            } else if (message.optString("event") == "broadcast") {
                                val payload = message.optJSONObject("payload")
                                if (payload?.optString("event") == "queue_changed") signal()
                            } else if (message.optString("event") == "phx_error" ||
                                message.optString("event") == "phx_close") {
                                latch.countDown()
                            }
                        } catch (_: Exception) { }
                    }

                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                        latch.countDown()
                    }

                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                        latch.countDown()
                    }
                })
                socket = ws

                // Phoenix heartbeat keeps the Realtime channel alive during long idle periods.
                val heartbeat = thread(name = "sabor-realtime-heartbeat") {
                    var ref = 2
                    while (active && !latch.await(25, TimeUnit.SECONDS)) {
                        val current = socket ?: break
                        val frame = JSONObject()
                            .put("topic", "phoenix")
                            .put("event", "heartbeat")
                            .put("payload", JSONObject())
                            .put("ref", (ref++).toString())
                        if (!current.send(frame.toString())) break
                    }
                }

                latch.await(70, TimeUnit.SECONDS)
                try { ws.close(1000, "reconnect") } catch (_: Exception) { }
                try { heartbeat.interrupt() } catch (_: Exception) { }
                if (active) Thread.sleep(delayMs)
            } catch (_: InterruptedException) {
                break
            } catch (_: Exception) {
                if (active) try { Thread.sleep(delayMs) } catch (_: InterruptedException) { break }
            } finally {
                socket = null
                delayMs = (delayMs * 2).coerceAtMost(60000L)
            }
        }
    }

    fun close() {
        active = false
        synchronized(monitor) { monitor.notifyAll() }
        try { socket?.close(1000, "service stopped") } catch (_: Exception) { }
        socket = null
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
    }

    companion object {
        private const val REALTIME_URL = "wss://enakuleybfvzqurrttwl.supabase.co/realtime/v1/websocket"
        private const val PUBLISHABLE_KEY = "sb_publishable_JnYedcVNm6Q2tao49qaYzQ_qxjelyqA"
        private const val TOPIC = "realtime:printer-queue"
    }
}
