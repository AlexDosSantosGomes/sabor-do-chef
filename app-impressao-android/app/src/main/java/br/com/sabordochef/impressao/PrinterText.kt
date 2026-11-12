package br.com.sabordochef.impressao

import java.nio.charset.Charset

/**
 * Codificação ESC/POS para impressoras térmicas configuradas com a página PC860
 * (português). Usa Windows-1252 como alternativa caso IBM860 não esteja disponível.
 */
object PrinterText {
    private val encoding = try {
        Charset.forName("IBM860") to 3.toByte()
    } catch (_: Exception) {
        Charset.forName("windows-1252") to 16.toByte()
    }
    private val printerCharset: Charset = encoding.first
    private val codePage: Byte = encoding.second

    fun initialize(): ByteArray = byteArrayOf(
        0x1B, 0x40,
        0x1B, 0x74, codePage
    )

    fun encode(value: String): ByteArray = value.toByteArray(printerCharset)
}
