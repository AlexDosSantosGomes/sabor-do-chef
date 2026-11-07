package br.com.sabordochef.impressao

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64

/**
 * Ponte compatível com o formato de envio usado atualmente pelo painel:
 * intent:base64,<conteúdo>#Intent;scheme=rawbt;package=ru.a402d.rawbtprinter;end;
 *
 * O chamador deve fornecer o conteúdo ESC/POS completo das duas vias.
 */
object RawBtBridge {
    fun sendEscPos(context: Context, bytes: ByteArray) {
        val base64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
        val uri = Uri.parse(
            "intent:base64,$base64#Intent;scheme=rawbt;package=ru.a402d.rawbtprinter;end;"
        )
        val intent = Intent(Intent.ACTION_VIEW, uri).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }
}
