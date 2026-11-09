package br.com.sabordochef.impressao

import java.nio.charset.Charset

/**
 * Codificação ESC/POS para impressoras térmicas configuradas com a página PC860
 * (português). Usa Windows-1252 como alternativa caso IBM860 não esteja disponível.
 */
object PrinterText {
    private val printerCharset: Charset
    private val codePage: Byte

    init {
        try {
            printerCharset = Charset.forName("IBM860")
            codePage = 3
        } catch (_: Exception) {
            printerCharset = Charset.forName("windows-1252")
            codePage = 16
        }
    }

    fun initialize(): ByteArray = byteArrayOf(
        0x1B, 0x40,       // ESC @: inicializa a impressora
        0x1B, 0x74, codePage // ESC t n: seleciona a página de caracteres
    )

    fun encode(value: String): ByteArray = value.toByteArray(printerCharset)
}
