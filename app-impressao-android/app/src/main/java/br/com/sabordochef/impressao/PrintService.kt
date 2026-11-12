package br.com.sabordochef.impressao

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.text.NumberFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.concurrent.thread

class PrintService : Service() {
    @Volatile private var running = false
    private var worker: Thread? = null
    private var cpuWakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        cpuWakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "SaborDoChef:PrintService"
        ).apply { acquire() }
        savePrinterState(STATE_RECONNECTING, "Iniciando conexão com a impressora")
        startForeground(NOTIFICATION_ID, buildNotification("Central ativa — conectando à impressora"))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!running) {
            running = true
            worker = thread(name = "sabor-print-queue") { pollQueue() }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        worker?.interrupt()
        BluetoothPrinter.disconnect()
        savePrinterState(STATE_DISCONNECTED, "Central parada")
        cpuWakeLock?.let { if (it.isHeld) it.release() }
        cpuWakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun pollQueue() {
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        val token = prefs.getString("device_token", "").orEmpty()
        if (token.length < 32) {
            updateNotification("Código de conexão não configurado")
            stopSelf()
            return
        }

        while (running && !Thread.currentThread().isInterrupted) {
            try {
                // Não reivindica pedidos enquanto a impressora estiver desconectada.
                // Assim eles permanecem pendentes no servidor até a reconexão.
                if (BluetoothPrinter.state() != BluetoothPrinter.State.CONNECTED) {
                    savePrinterState(STATE_RECONNECTING, "Tentando conectar à Bluetooth Printer")
                    updateNotification("Impressora: tentando conectar")
                    try {
                        val connectStarted = System.nanoTime()
                        BluetoothPrinter.connect(this)
                        prefs.edit().putLong("last_connect_ms", elapsedMs(connectStarted)).apply()
                        savePrinterState(STATE_CONNECTED, "Bluetooth Printer conectada")
                        updateNotification("Impressora conectada — aguardando pedidos")
                    } catch (connectionError: Exception) {
                        savePrinterState(STATE_DISCONNECTED, connectionError.message ?: "Impressora desconectada")
                        updateNotification("Impressora desconectada — nova tentativa em 5 segundos")
                        Thread.sleep(RECONNECT_DELAY_MS)
                        continue
                    }
                } else {
                    savePrinterState(STATE_CONNECTED, "Bluetooth Printer conectada")
                }

                val pendingAckId = prefs.getString("pending_ack_job_id", null)
                if (!pendingAckId.isNullOrBlank()) {
                    if (confirmSentJob(token, pendingAckId)) Thread.sleep(1500)
                    else Thread.sleep(8000)
                    continue
                }

                val claimStarted = System.nanoTime()
                val response = api(token, JSONObject().put("action", "claim"))
                val claimMs = elapsedMs(claimStarted)
                if (response.has("error")) throw IllegalStateException(response.optString("error"))
                val job = response.optJSONObject("job")
                if (job == null || job.length() == 0) {
                    updateNotification("Impressora conectada — aguardando pedidos")
                    Thread.sleep(POLL_INTERVAL_MS)
                    continue
                }

                val jobId = job.getString("id")
                val sendStarted = System.nanoTime()
                try {
                    val bytes = buildTickets(job)
                    BluetoothPrinter.sendEscPos(this, bytes)
                    val sendMs = elapsedMs(sendStarted)
                    prefs.edit()
                        .putLong("last_claim_ms", claimMs)
                        .putLong("last_send_ms", sendMs)
                        .putLong("last_print_started_at", System.currentTimeMillis())
                        .putString("last_print_status", "Enviado à impressora")
                        .apply()
                } catch (printError: Exception) {
                    BluetoothPrinter.disconnect()
                    savePrinterState(STATE_DISCONNECTED, printError.message ?: "Falha na conexão Bluetooth")
                    try {
                        api(token, JSONObject()
                            .put("action", "fail")
                            .put("job_id", jobId)
                            .put("error", printError.message ?: "Falha ao enviar via Bluetooth"))
                    } catch (_: Exception) { }
                    updateNotification("Impressora indisponível. Pedido mantido para nova tentativa.")
                    Thread.sleep(RECONNECT_DELAY_MS)
                    continue
                }

                // Preserva a proteção existente: registra o ACK antes de consultar outra tarefa.
                prefs.edit().putString("pending_ack_job_id", jobId).apply()
                val ackStarted = System.nanoTime()
                if (confirmSentJob(token, jobId)) {
                    val ackMs = elapsedMs(ackStarted)
                    val totalMs = prefs.getLong("last_claim_ms", 0L) +
                        prefs.getLong("last_send_ms", 0L) + ackMs
                    prefs.edit()
                        .putLong("last_ack_ms", ackMs)
                        .putLong("last_print_total_ms", totalMs)
                        .putString("last_print_status", "Concluída e confirmada no painel")
                        .apply()
                    Thread.sleep(1500)
                } else {
                    Thread.sleep(8000)
                }
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            } catch (e: Exception) {
                updateNotification("Erro na fila ou internet. Tentando novamente.")
                try { Thread.sleep(10000) } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
        }
    }

    private fun confirmSentJob(token: String, jobId: String): Boolean {
        return try {
            api(token, JSONObject().put("action", "complete").put("job_id", jobId))
            getSharedPreferences(PREFS, MODE_PRIVATE)
                .edit().remove("pending_ack_job_id").apply()
            updateNotification("Pedido enviado à impressora e registrado no painel")
            true
        } catch (_: Exception) {
            updateNotification("Nota enviada; aguardando confirmação do painel.")
            false
        }
    }

    private fun api(token: String, body: JSONObject): JSONObject {
        val connection = (URL(API_URL).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 15000
            readTimeout = 20000
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("x-device-token", token)
        }
        try {
            connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val text = BufferedReader(InputStreamReader(stream, Charsets.UTF_8)).use { it.readText() }
            val json = if (text.isBlank()) JSONObject() else JSONObject(text)
            if (code !in 200..299) throw IllegalStateException(json.optString("error", "Erro HTTP $code"))
            return json
        } finally {
            connection.disconnect()
        }
    }

    private fun buildTickets(job: JSONObject): ByteArray {
        val order = job.getJSONObject("order")
        val items = job.optJSONArray("items")
        val accompaniments = job.optJSONArray("accompaniments")
        val accByItem = mutableMapOf<String, MutableList<String>>()
        if (accompaniments != null) {
            for (i in 0 until accompaniments.length()) {
                val acc = accompaniments.getJSONObject(i)
                val key = acc.optString("order_item_id")
                accByItem.getOrPut(key) { mutableListOf() }.add(acc.optString("accompaniment_name"))
            }
        }

        if (order.optString("order_type").equals("PICKUP", ignoreCase = true)) {
            return buildPickupTickets(order, items, accByItem)
        }

        val number = order.optString("order_number", "N/I")
        // A data/hora vem do registro original do pedido, nunca do momento da impressão.
        val orderDateTime = formatOrderDateTime(
            order.optString("created_at", order.optString("createdAt", ""))
        )
        val dateLine = "DATA: ${orderDateTime.first}    HORA: ${orderDateTime.second}"
        val customer = order.optString("customer_name", "Não informado")
        val phone = order.optString("customer_phone", "Não informado")
        val address = order.optString("delivery_address", "Não informado")

        val payment = when (order.optString("payment_method").uppercase(Locale.ROOT)) {
            "CASH" -> "Dinheiro na entrega"
            "PIX" -> "Pix na entrega"
            "CARD" -> "Cartão na entrega"
            "PAGAMENTO_NA_ENTREGA" -> "Pagamento na entrega"
            else -> order.optString("payment_method", "Pagamento na entrega").replace("_", " ")
        }
        val currency = formatCurrencyCents(order.optLong("total_cents", 0L))

        // Via do caixa: mostra o preço unitário de cada produto para conferência.
        val caixa = StringBuilder()
            .append("SABOR DO CHEF\n")
            .append("VIA DO CAIXA\n")
            .append("--------------------------------\n")
            .append("PEDIDO #").append(number).append("\n")
            .append(dateLine).append("\n")
            .append("CLIENTE: ").append(customer).append("\n")
            .append("TELEFONE: ").append(phone).append("\n")
            .append("ENDEREÇO: ").append(address).append("\n")
            .append("--------------------------------\nITENS\n")
        if (items != null) {
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                val quantity = item.optInt("quantity", 1)
                caixa.append(quantity).append("x ")
                    .append(item.optString("product_name_snapshot")).append(" - ")
                    .append(formatItemUnitPrice(item)).append("\n")
                accByItem[item.optString("id")]?.forEach { caixa.append("  + ").append(it).append("\n") }
                val notes = item.optString("notes")
                if (notes.isNotBlank() && notes != "null") caixa.append("  Obs: ").append(notes).append("\n")
            }
        }
        val customerNotes = order.optString("customer_notes")
        if (customerNotes.isNotBlank() && customerNotes != "null") {
            caixa.append("--------------------------------\nOBS: ").append(customerNotes).append("\n")
        }
        caixa.append("--------------------------------\n")
            .append("TOTAL: ").append(currency).append("\n")
            .append("PAGAMENTO: ").append(payment).append("\n")
            .append("ENTREGA GRÁTIS\n")
            .append("--------------------------------\n")
            .append("OBRIGADO PELA PREFERÊNCIA!\n")
            .append("SABOR DO CHEF\n\n\n")

        val motoboy = StringBuilder()
            .append("SABOR DO CHEF\n")
            .append("VIA DO MOTOBOY\n")
            .append("--------------------------------\n")
            .append("PEDIDO #").append(number).append("\n")
            .append(dateLine).append("\n")
            .append("CLIENTE: ").append(customer).append("\n")
            .append("TELEFONE: ").append(phone).append("\n")
            .append("ENDEREÇO: ").append(address).append("\n")
            .append("PAGAMENTO: ").append(payment).append("\n")
            .append("TOTAL: ").append(currency).append("\n")
            .append("--------------------------------\nITENS\n")
        if (items != null) {
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                motoboy.append(item.optInt("quantity", 1)).append("x ")
                    .append(item.optString("product_name_snapshot")).append("\n")
                accByItem[item.optString("id")]?.forEach { motoboy.append("  + ").append(it).append("\n") }
                val notes = item.optString("notes")
                if (notes.isNotBlank() && notes != "null") motoboy.append("  Obs: ").append(notes).append("\n")
            }
        }
        motoboy.append("--------------------------------\n")
            .append("ENTREGA GRÁTIS\n")
            .append("OBRIGADO PELA PREFERÊNCIA!\n")
            .append("SABOR DO CHEF\n\n\n")

        val out = java.io.ByteArrayOutputStream()
        out.write(PrinterText.initialize())
        out.write(PrinterText.encode(caixa.toString()))
        out.write(byteArrayOf(0x1B, 0x64, 0x03, 0x1D, 0x56, 0x00))
        out.write(PrinterText.encode(motoboy.toString()))
        out.write(byteArrayOf(0x1B, 0x64, 0x03, 0x1D, 0x56, 0x00))
        return out.toByteArray()
    }

    private fun buildPickupTickets(
        order: JSONObject,
        items: org.json.JSONArray?,
        accByItem: Map<String, List<String>>
    ): ByteArray {
        val number = order.optString("order_number", "N/I")
        val createdAt = order.optString("created_at", order.optString("createdAt", ""))
        val createdInstant = try { Instant.parse(createdAt) } catch (_: Exception) { null }
        val localDate = createdInstant?.atZone(ZoneId.of("America/Sao_Paulo"))
        val date = localDate?.format(DateTimeFormatter.ofPattern("dd/MM/yyyy", Locale("pt", "BR"))) ?: "N/I"
        val time = localDate?.format(DateTimeFormatter.ofPattern("HH:mm", Locale("pt", "BR"))) ?: "N/I"
        val totalCents = order.optLong("total_cents", 0L)
        val payment = when (order.optString("payment_method").uppercase(Locale.ROOT)) {
            "CASH" -> "DINHEIRO"
            "PIX" -> "PIX"
            "CARD" -> "CARTÃO"
            else -> order.optString("payment_method", "Não informado").uppercase(Locale("pt", "BR"))
        }

        val ticket = StringBuilder()
            .append("SABOR DO CHEF\n")
            .append("COMANDA DE PEDIDO\n")
            .append("================================\n")
            .append("              RETIRADA\n")
            .append("================================\n")
            .append("PEDIDO Nº ").append(number).append("\n")
            .append("Data: ").append(date).append("\n")
            .append("Horário do pedido: ").append(time).append("\n")
            .append("Cliente: ").append(order.optString("customer_name", "Não informado")).append("\n")
            .append("Telefone: ").append(order.optString("customer_phone", "Não informado")).append("\n")
            .append("--------------------------------\n")
            .append("PRODUTOS\n")

        if (items != null) {
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                ticket.append(item.optInt("quantity", 1)).append("x ")
                    .append(item.optString("product_name_snapshot")).append("\n")
                accByItem[item.optString("id")]?.forEach { ticket.append("  + ").append(it).append("\n") }
                val notes = item.optString("notes")
                if (notes.isNotBlank() && notes != "null") ticket.append("  Obs: ").append(notes).append("\n")
            }
        }

        val customerNotes = order.optString("customer_notes")
        if (customerNotes.isNotBlank() && customerNotes != "null") {
            ticket.append("--------------------------------\nOBS: ").append(customerNotes).append("\n")
        }

        if (order.optBoolean("needs_change")) {
            val changeFor = order.optLong("change_for_cents", 0L)
            val changeDue = changeFor - totalCents
            ticket.append("--------------------------------\n")
                .append("Vai pagar com: ").append(formatCurrencyCents(changeFor)).append("\n")
                .append("Troco: ").append(formatCurrencyCents(changeDue)).append("\n")
        }

        ticket.append("--------------------------------\n")
            .append("TOTAL: ").append(formatCurrencyCents(totalCents)).append("\n")
            .append("FORMA DE PAGAMENTO: ").append(payment).append("\n")
            .append("PAGAMENTO NA RETIRADA\n")
            .append("--------------------------------\n")
            .append("              RETIRADA\n")
            .append("\n\n")

        val copy = PrinterText.encode(ticket.toString())
        val cut = byteArrayOf(0x1B, 0x64, 0x03, 0x1D, 0x56, 0x00)
        val out = java.io.ByteArrayOutputStream()
        out.write(PrinterText.initialize())
        out.write(copy)
        out.write(cut)
        out.write(copy)
        out.write(cut)
        return out.toByteArray()
    }

    private fun formatOrderDateTime(rawTimestamp: String): Pair<String, String> {
        if (rawTimestamp.isBlank() || rawTimestamp == "null") return "N/I" to "N/I"
        val patterns = listOf(
            "yyyy-MM-dd'T'HH:mm:ss.SSSX",
            "yyyy-MM-dd'T'HH:mm:ssX",
            "yyyy-MM-dd HH:mm:ss"
        )
        for (pattern in patterns) {
            try {
                val parser = SimpleDateFormat(pattern, Locale.US).apply {
                    isLenient = false
                    timeZone = TimeZone.getTimeZone("UTC")
                }
                val parsed = parser.parse(rawTimestamp) ?: continue
                val localTimeZone = TimeZone.getTimeZone("America/Sao_Paulo")
                val date = SimpleDateFormat("dd/MM/yyyy", Locale("pt", "BR")).apply {
                    timeZone = localTimeZone
                }.format(parsed)
                val time = SimpleDateFormat("HH:mm", Locale("pt", "BR")).apply {
                    timeZone = localTimeZone
                }.format(parsed)
                return date to time
            } catch (_: Exception) {
                // Tenta o próximo formato conhecido de timestamp.
            }
        }
        return "N/I" to "N/I"
    }

    private fun formatItemUnitPrice(item: JSONObject): String {
        val centsKeys = listOf("unit_price_cents", "price_cents", "unit_price_snapshot_cents")
        for (key in centsKeys) {
            if (item.has(key) && !item.isNull(key)) {
                return formatCurrencyCents(item.optLong(key, 0L))
            }
        }
        val decimalKeys = listOf("unit_price", "price", "unit_price_snapshot")
        for (key in decimalKeys) {
            if (item.has(key) && !item.isNull(key)) {
                val value = item.optDouble(key, Double.NaN)
                if (!value.isNaN() && !value.isInfinite()) {
                    return formatCurrencyCents(kotlin.math.round(value * 100.0).toLong())
                }
            }
        }
        return "—"
    }

    private fun formatCurrencyCents(totalCents: Long): String {
        val whole = totalCents / 100
        val cents = kotlin.math.abs(totalCents % 100).toString().padStart(2, '0')
        val integerFormat = NumberFormat.getIntegerInstance(Locale("pt", "BR"))
        return "R$ ${integerFormat.format(whole)},$cents"
    }

    private fun elapsedMs(startedAt: Long): Long =
        (System.nanoTime() - startedAt) / 1_000_000L

    private fun savePrinterState(state: String, detail: String) {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putString("printer_connection_state", state)
            .putString("printer_connection_detail", detail)
            .apply()
    }

    private fun updateNotification(message: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(message))
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Central de impressão", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(message: String): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_info_details)
            .setContentTitle("Sabor do Chef")
            .setContentText(message)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

    companion object {
        private const val PREFS = "printer_config"
        private const val API_URL = "https://enakuleybfvzqurrttwl.supabase.co/functions/v1/printer-device-api"
        private const val CHANNEL_ID = "sabor_do_chef_print_service"
        private const val NOTIFICATION_ID = 4107
        private const val POLL_INTERVAL_MS = 2000L
        private const val RECONNECT_DELAY_MS = 5000L
        private const val STATE_DISCONNECTED = "DISCONNECTED"
        private const val STATE_RECONNECTING = "RECONNECTING"
        private const val STATE_CONNECTED = "CONNECTED"
    }
}
