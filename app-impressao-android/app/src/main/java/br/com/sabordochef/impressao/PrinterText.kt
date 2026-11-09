package br.com.sabordochef.impressao

import java.nio.charset.Charset
import java.text.Normalizer

/**
 * Texto para impressoras térmicas ESC/POS.
 *
 * Usa Windows-1252 (página WPC1252) para manter corretamente os caracteres
 * portugueses: á, à, â, ã, é, ê, í, ó, ô, õ, ú, ç e Ç.
 */
object PrinterText {
    private val printerCharset: Charset = Charset.forName("windows-1252")

    // ESC t 16: página WPC1252 em impressoras compatíveis com Epson ESC/POS.
    private const val CODE_PAGE: Byte = 16

    fun initialize(): ByteArray = byteArrayOf(
        0x1B, 0x40,             // ESC @: inicializa a impressora
        0x1B, 0x74, CODE_PAGE   // ESC t 16: seleciona Windows-1252
    )

    fun encode(value: String): ByteArray {
        // NFC evita sequências Unicode decompostas que não existem no Windows-1252.
        val normalized = Normalizer.normalize(value, Normalizer.Form.NFC)
        return normalized.toByteArray(printerCharset)
    }
}
