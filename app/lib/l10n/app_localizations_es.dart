// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get modelsDownloadFailed =>
      'No se pudieron descargar los modelos de voz.';

  @override
  String get modelsPreparing => 'Preparando…';

  @override
  String get modelsFirstRunNote =>
      'Solo la primera vez. Todo se procesa en este Mac.';

  @override
  String modelDownloading(String model) {
    return 'Descargando $model…';
  }

  @override
  String modelInstalling(String model) {
    return 'Instalando $model…';
  }

  @override
  String get modelVad => 'Detector de voz';

  @override
  String get modelStt => 'Reconocimiento de voz (Parakeet v3)';

  @override
  String get modelVoice => 'Voz (Supertonic 3)';

  @override
  String startFailed(String error) {
    return 'No se pudo arrancar: $error';
  }

  @override
  String get loadingVoice => 'Cargando la voz…';

  @override
  String backgroundJobs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count workers trabajando',
      one: '1 worker trabajando',
    );
    return '$_temp0';
  }

  @override
  String get micMuted => 'Micrófono silenciado · espacio para activar';

  @override
  String micMutedKey(String key) {
    return 'Micrófono silenciado · $key para activar';
  }

  @override
  String get muteKey => 'Tecla de silencio';

  @override
  String muteKeyCurrent(String key) {
    return 'Silencia y activa el micrófono: $key';
  }

  @override
  String get muteKeyHint =>
      'Una tecla sola funciona mientras Minerva está en pantalla y no estás escribiendo. Bloq Mayús y las combinaciones con ⌘ o ⌃ funcionan en cualquier app, también con Minerva cerrada.';

  @override
  String get muteKeyRecording =>
      'Pulsa la nueva tecla o combinación… (Esc cancela)';

  @override
  String get muteKeyChange => 'Cambiar';

  @override
  String get muteKeyCapsLock => 'Usar Bloq Mayús';

  @override
  String get muteKeyReset => 'Volver a Espacio';

  @override
  String get muteKeyNoAccess =>
      'Para usarla en otras apps, Minerva necesita Accesibilidad (y quizá Monitorización de entrada) en Ajustes del Sistema → Privacidad y seguridad.';

  @override
  String get muteKeyGrant => 'Abrir ajustes';

  @override
  String get keySpace => 'Espacio';

  @override
  String get keyCapsLock => 'Bloq Mayús';

  @override
  String get linkNoteOnPhone => 'Móvil conectado · el Mac está en silencio';

  @override
  String get phoneConnected => 'Móvil conectado';

  @override
  String get phoneConnect => 'Conectar el móvil';

  @override
  String get pairingConnected =>
      'Móvil conectado. Mientras lo esté, el Mac no escucha ni habla.';

  @override
  String get pairingWaiting => 'Esperando al móvil…';

  @override
  String get connectingToRelay => 'Conectando con el intermediario…';

  @override
  String get pairingInstructions =>
      'Escanéalo con la app Minerva del móvil. El móvil será el micrófono, el altavoz y la pantalla; todo se sigue procesando en este Mac.';

  @override
  String get pairingNewCode => 'Nuevo código';

  @override
  String get close => 'Cerrar';

  @override
  String get copy => 'Copiar';

  @override
  String get webhooks => 'Webhooks';

  @override
  String get webhooksActive => 'Webhooks activos';

  @override
  String get webhooksExplanation =>
      'Otros servicios pueden avisar a Minerva llamando a la dirección de un webhook (con cualquier ruta detrás). Cada webhook tiene su propia dirección secreta; pídele a Minerva que cree uno para cada servicio. El cifrado termina en este Mac: el intermediario no ve lo que llega. Mantén las direcciones en privado: quien tenga una puede escribir a Minerva.';

  @override
  String get webhooksNone =>
      'Aún no hay webhooks. Pídele a Minerva que cree uno.';

  @override
  String get addressCopied => 'Dirección copiada';

  @override
  String get webhooksHelperMissing =>
      'Falta el ayudante minerva-webhooks en la app.';

  @override
  String webhooksHelperCrashes(int code) {
    return 'El ayudante de webhooks se cierra al arrancar (código $code).';
  }

  @override
  String webhooksHelperFailed(String error) {
    return 'No se pudo arrancar minerva-webhooks: $error';
  }

  @override
  String get webhooksStarting => 'Arrancando…';

  @override
  String get webhooksRequestingCert => 'Pidiendo el certificado…';

  @override
  String webhooksNoCert(String error) {
    return 'Sin certificado todavía: $error';
  }

  @override
  String get webhooksOn => 'Activo';

  @override
  String get activityThinking => 'Pensando…';

  @override
  String get activityCompacting => 'Resumiendo la conversación…';

  @override
  String get activityWebSearch => 'Buscando en la web…';

  @override
  String get activityWebFetch => 'Leyendo una página…';

  @override
  String get activityLookingAtScreen => 'Mirando la pantalla…';

  @override
  String get activityPreparingDisplay => 'Preparando la pantalla…';

  @override
  String get activityRemembering => 'Recordando…';

  @override
  String get activitySearchingHistory => 'Buscando en el historial…';

  @override
  String get activityReadingSkill => 'Repasando cómo se hace…';

  @override
  String get activityStartingWorker => 'Lanzando trabajo en segundo plano…';

  @override
  String get activityCheckingWorkers => 'Mirando los trabajos en curso…';

  @override
  String get activityScheduling => 'Programando…';

  @override
  String get activityWebhooks => 'Configurando webhooks…';

  @override
  String get activitySendingFile => 'Enviándolo por Telegram…';

  @override
  String get activityTakingPhoto => 'Sacando una foto…';

  @override
  String get activityRunningCommand => 'Ejecutando un comando…';

  @override
  String get activityReadingFiles => 'Leyendo ficheros…';

  @override
  String get activityWritingFile => 'Escribiendo un fichero…';

  @override
  String get activityReadingUi => 'Leyendo la interfaz…';

  @override
  String get activityUsingComputer => 'Usando el ordenador…';

  @override
  String get brainError =>
      'Ha habido un error con el cerebro. Vuelve a intentarlo.';

  @override
  String get reminderLead => 'Te recuerdo';

  @override
  String get unpair => 'Desvincular del ordenador';

  @override
  String get notMinervaCode => 'Ese código no es de Minerva.';

  @override
  String get pairScreenInstructions =>
      'En el ordenador, pulsa el botón del móvil en la barra de abajo y escanea el código.';

  @override
  String get pairScreenNote =>
      'El móvil será el micrófono, el altavoz y la pantalla; todo se procesa en el ordenador.';

  @override
  String get scanCode => 'Escanear el código';

  @override
  String get remoteReplaced => 'Otro móvil está conectado a este ordenador';

  @override
  String get remoteConnecting => 'Conectando…';

  @override
  String get remoteWaitingHost =>
      'Esperando al ordenador… (abre Minerva en él)';

  @override
  String micFailed(String error) {
    return 'No se pudo usar el micrófono: $error';
  }

  @override
  String get displaySubmit => 'Enviar';

  @override
  String get displaySubmitted => 'Enviado';

  @override
  String get displayRequired => 'Obligatorio';

  @override
  String get displayPickDate => 'Elegir fecha';

  @override
  String get displayVideoError => 'No se puede reproducir el vídeo';

  @override
  String get displayYes => 'Sí';

  @override
  String get displayNo => 'No';

  @override
  String vaultFormTitle(String name) {
    return 'Credencial: $name';
  }

  @override
  String get vaultFormNote =>
      'Se guarda en la caja fuerte cifrada de Minerva en este Mac. El asistente nunca ve lo que escribes aquí.';

  @override
  String get vaultSave => 'Guardar';

  @override
  String get vaultSaved => 'Guardado';

  @override
  String get cancel => 'Cancelar';

  @override
  String get vaultShowSecret => 'Mostrar';

  @override
  String get vaultHideSecret => 'Ocultar';

  @override
  String get vaultCredentials => 'Credenciales';

  @override
  String get vaultDialogIntro =>
      'Accesos y tokens que el asistente puede usar sin verlos. Para añadir uno, pídeselo al asistente; te mostrará un formulario.';

  @override
  String get vaultEmpty => 'Aún no hay credenciales guardadas.';

  @override
  String get delete => 'Borrar';

  @override
  String vaultDeleteConfirm(String name) {
    return '¿Borrar la credencial «$name»?';
  }

  @override
  String vaultFields(String names) {
    return 'Campos: $names';
  }

  @override
  String vaultUnavailable(String error) {
    return 'La caja fuerte no está disponible: $error';
  }

  @override
  String get language => 'Idioma';

  @override
  String get languageSystem => 'Idioma del sistema';

  @override
  String get modelTitle => 'Modelo';

  @override
  String get modelConversation => 'Conversación';

  @override
  String get modelWorkers => 'Workers';

  @override
  String get modelSearch => 'Buscar modelos';

  @override
  String get modelDefault => 'predeterminado';

  @override
  String modelPrevious(int count) {
    return 'Modelos anteriores ($count)';
  }

  @override
  String get modelNoMatch => 'Ningún modelo coincide';

  @override
  String modelLoading(String agent) {
    return 'Cargando los modelos de $agent…';
  }

  @override
  String modelUnavailable(String agent) {
    return '$agent no está instalado o no tiene la sesión iniciada. Instálalo e inicia sesión desde una terminal (para Antigravity: ejecuta agy; para Codex: ejecuta codex login).';
  }

  @override
  String get modelProviderNote =>
      'Cada proveedor tiene su propia conversación.';

  @override
  String get modelEffort => 'Esfuerzo';

  @override
  String get effortLow => 'Bajo';

  @override
  String get effortMedium => 'Medio';

  @override
  String get effortHigh => 'Alto';

  @override
  String get effortXhigh => 'Muy alto';

  @override
  String get effortMax => 'Máximo';

  @override
  String get effortUltra => 'Ultra';

  @override
  String get modelSpeed => 'Velocidad';

  @override
  String get speedStandard => 'Estándar';

  @override
  String get speedFast => 'Rápida';

  @override
  String fastUnavailable(String reason) {
    return 'El modo rápido no está disponible: $reason';
  }

  @override
  String get fastExtraUsageDisabled =>
      'el uso extra está desactivado en tu cuenta de Claude';

  @override
  String get modelConversationNote =>
      'La conversación sigue con el nuevo modelo.';

  @override
  String get modelWorkersNote =>
      'Se aplica a los workers que empiecen a partir de ahora.';

  @override
  String get modelProviders => 'Proveedores';

  @override
  String get providerReady => 'Listo';

  @override
  String get providerChecking => 'Comprobando…';

  @override
  String get providerUnavailable => 'No instalado o sin sesión iniciada';

  @override
  String providerLimited(String time) {
    return 'Límite de uso hasta las $time';
  }

  @override
  String providerSignedOut(String time) {
    return 'Sin sesión: vuelve a iniciarla desde una terminal (reintento a las $time)';
  }

  @override
  String providerUsedBy(String uses) {
    return 'En uso: $uses';
  }

  @override
  String get providersNote =>
      'Minerva usa las suscripciones de los agentes instalados en este Mac: Claude Code (claude), Antigravity (agy) y Codex (codex login). Conecta varios y añade respaldos: cuando uno llega a su límite de uso, Minerva sigue con el siguiente.';

  @override
  String get fallbacks => 'Respaldos, por orden';

  @override
  String get fallbacksNote =>
      'Cuando un proveedor llega a su límite de uso, Minerva sigue con el siguiente respaldo, y vuelve a la primera opción cuando el límite termina.';

  @override
  String get fallbacksNone =>
      'Sin respaldos: si el proveedor no está disponible, Minerva lo dice y espera.';

  @override
  String get fallbackAdd => 'Añadir respaldo';

  @override
  String get fallbackRemove => 'Quitar';

  @override
  String get fallbackUp => 'Subir';

  @override
  String get fallbackDown => 'Bajar';

  @override
  String modelOnBackup(String provider, String model) {
    return '$provider no está disponible: la conversación sigue con $model hasta que vuelva.';
  }

  @override
  String providerFellBack(String from, String to) {
    return '$from no puede responder ahora. Sigo con $to.';
  }

  @override
  String get settings => 'Ajustes';

  @override
  String get settingsOffline =>
      'Conecta con el ordenador para cambiar sus ajustes.';

  @override
  String get settingsAppliedOnComputer =>
      'Son los ajustes del ordenador: los cambios se aplican a Minerva allí.';

  @override
  String get voice => 'Voz';

  @override
  String voiceFemale(int n) {
    return 'Femenina $n';
  }

  @override
  String voiceMale(int n) {
    return 'Masculina $n';
  }

  @override
  String get phoneOverlay => 'Orbe sobre otras apps';

  @override
  String get phoneOverlayOn =>
      'Activado: el orbe de Minerva flota sobre las demás apps mientras está conectada';

  @override
  String get phoneOverlayOff =>
      'Desactivado: permite mostrar sobre otras apps para ver el orbe de Minerva fuera de la app';

  @override
  String get telegramUnsupported =>
      'Aquí todavía no puedo con vídeo, stickers ni ubicaciones. Escríbemelo, por favor.';

  @override
  String get telegramDownloadFailed =>
      'No he podido descargar eso de Telegram. Prueba a enviarlo otra vez.';

  @override
  String get telegramTranscribeFailed =>
      'No he podido transcribir ese audio. Prueba otra vez o escríbemelo.';

  @override
  String get telegramNoSpeech => 'No he entendido ninguna voz en ese audio.';

  @override
  String get telegramBadToken =>
      'Telegram ha rechazado el token del bot: guarda uno válido como credencial telegram (campo token).';

  @override
  String get telegramConflict =>
      'Este bot de Telegram tiene un webhook o lo lee otro programa: Minerva necesita un bot propio.';

  @override
  String get usageSessionLimit => 'Límite de 5 horas';

  @override
  String get usageWeekLimit => 'Límite semanal';

  @override
  String usageOtherLimit(int hours) {
    return 'Límite de $hours horas';
  }

  @override
  String usageLeft(int percent) {
    return 'queda un $percent %';
  }

  @override
  String usageResets(String when) {
    return 'se reinicia $when';
  }

  @override
  String usageProjection(int percent) {
    return 'proyección: $percent % al reiniciarse';
  }

  @override
  String usageRunsOutAt(String time) {
    return 'se agota hacia las $time';
  }

  @override
  String usageRunsOutOn(String when) {
    return 'se agota hacia el $when';
  }

  @override
  String get usageSpent => 'límite alcanzado';

  @override
  String get workerRunning => 'Trabajando';

  @override
  String get workerDone => 'Terminado';

  @override
  String get workerFailed => 'Falló';

  @override
  String get workerStopped => 'Detenido';

  @override
  String get workerInterrupted => 'Interrumpido';

  @override
  String get workerStarting => 'Empezando…';

  @override
  String workersMore(int count) {
    return '+$count más';
  }

  @override
  String projectEdited(String when) {
    return 'Modificado $when';
  }

  @override
  String get timeJustNow => 'ahora mismo';

  @override
  String timeMinutesAgo(int count) {
    return 'hace $count min';
  }

  @override
  String timeHoursAgo(int count) {
    return 'hace $count h';
  }

  @override
  String timeDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'hace $count días',
      one: 'ayer',
    );
    return '$_temp0';
  }

  @override
  String get modelSpeaker => 'Identificación de voz (CAM++)';

  @override
  String get wakeMode => 'Palabra de activación';

  @override
  String get wakeModeOff => 'Desactivada';

  @override
  String get wakeModeOn => 'Siempre';

  @override
  String get wakeModeAuto => 'Por voz';

  @override
  String get wakeActive => 'Palabra de activación: di «Minerva…»';

  @override
  String get wakeTimeout => 'Desactivar tras';

  @override
  String wakeTimeoutMinutes(int minutes) {
    return 'Desactivar tras $minutes min';
  }

  @override
  String minutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get voiceIdLoading => 'Cargando la identificación de voz…';

  @override
  String voiceIdEnrolling(int done, int total) {
    return 'Aprendiendo tu voz ($done/$total)';
  }

  @override
  String get voiceIdReady => 'Tu voz está aprendida';

  @override
  String get voiceIdFailed => 'Identificación de voz no disponible';

  @override
  String get voiceIdReset => 'Volver a aprender mi voz';
}
