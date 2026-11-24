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
      other: '$count trabajos en segundo plano',
      one: '1 trabajo en segundo plano',
    );
    return '$_temp0';
  }

  @override
  String get micMuted => 'Micrófono silenciado · espacio para activar';

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
      'Otros servicios pueden avisar a Minerva llamando a esta dirección (con cualquier ruta detrás). El cifrado termina en este Mac: el intermediario no ve lo que llega. Mantenla en privado: quien la tenga puede escribir a Minerva.';

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
}
