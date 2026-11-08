package br.com.sabordochef.impressao

import android.content.Context
import android.content.Intent
import android.util.Base64

/**
 * Envia dados ESC/POS ao RawBT usando uma Intent URI.
 * A URI precisa ser interpretada por Intent.parseUri; Uri.parse
 * trataria "intent:" como um esquema comum e causaria ActivityNotFoundException.
 */
object RawBtBridge {
    fun sendEscPos(context: Context, bytes: ByteArray) {
        val base64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
        val intentUri =
            "intent:base64,$base64#Intent;scheme=rawbt;package=ru.a402d.rawbtprinter;end;"

        val intent = Intent.parseUri(intentUri, Intent.URI_INTENT_SCHEME).apply {
            action = Intent.ACTION_VIEW
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        // Confirma que há um aplicativo capaz de receber o envio antes de abrir.
        if (intent.resolveActivity(context.packageManager) == null) {
            throw IllegalStateException(
                "RawBT não encontrado. Confira se está instalado e atualizado."
            )
        }

        context.startActivity(intent)
    }
}
