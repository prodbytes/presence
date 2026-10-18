// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get aboutLinkCopied => 'Enlace copiado';

  @override
  String get aboutOpenSource => 'Presence es de código abierto:';

  @override
  String get aboutParagraph =>
      'Presence convierte un teléfono, tableta, portátil o Raspberry Pi en una cámara siempre activa para un lugar que cuidas: video en vivo, clips que incluyen los momentos previos y clips al detectar movimiento. Graba solo donde tengas permiso.';

  @override
  String get authAccessAdmin => 'Acceso admin';

  @override
  String get authAccessFree => 'Acceso gratis';

  @override
  String get authAccessPremium => 'Acceso Premium';

  @override
  String get authAccessPro => 'Acceso Pro';

  @override
  String get authBackedUp => 'Los clips y eventos tienen copia de seguridad';

  @override
  String authBackedUpBoth(int up, int down) {
    return 'Copia hecha ($up subidos, $down restaurados)';
  }

  @override
  String authBackedUpRestored(int down) {
    return 'Copia hecha ($down restaurados)';
  }

  @override
  String authBackedUpUploaded(int up) {
    return 'Copia hecha ($up subidos)';
  }

  @override
  String get authBackupOff => 'La copia en la nube está desactivada';

  @override
  String get authCheckAgain => 'Comprobar de nuevo';

  @override
  String get authCheckingRoles => 'Comprobando roles…';

  @override
  String get authDeleteAccount => 'Eliminar cuenta';

  @override
  String get authDeleteAccountCancel => 'Cancelar';

  @override
  String get authDeleteAccountChanged =>
      'El perfil de tu cuenta cambió. Cierra esto e inténtalo de nuevo.';

  @override
  String get authDeleteAccountConfirm => 'Entiendo que no se puede deshacer';

  @override
  String get authDeleteAccountDevice =>
      'También se eliminan las copias de los eventos y clips del perfil en este dispositivo, y se cierra tu sesión. No se puede deshacer.';

  @override
  String get authDeleteAccountDone => 'Se eliminaron tu cuenta y su perfil';

  @override
  String authDeleteAccountFailed(String error) {
    return 'No se pudo eliminar la cuenta ($error). Inténtalo de nuevo.';
  }

  @override
  String authDeleteAccountLinked(String email, String profile, String owner) {
    return '$email está vinculada al perfil $profile, de $owner. Eliminar tu cuenta la desvincula y elimina tus mensajes de Comentarios y ayuda; el perfil y sus datos siguen siendo de su dueño.';
  }

  @override
  String get authDeleteAccountManage => 'Cómo cancelar una suscripción';

  @override
  String authDeleteAccountOthers(String emails) {
    return 'Estas cuentas vinculadas a él también pierden el acceso: $emails.';
  }

  @override
  String authDeleteAccountOwner(String profile) {
    return 'Eres el dueño del perfil $profile. Eliminar tu cuenta elimina todo el perfil: sus eventos, clips, grabaciones y ajustes en la nube, sus mensajes de Comentarios y ayuda, sus etiquetas de reconocimiento y las claves de transmisión de sus dispositivos.';
  }

  @override
  String get authDeleteAccountSignInAgain =>
      'Vuelve a iniciar sesión y luego elimina la cuenta.';

  @override
  String get authDeleteAccountSubscription =>
      'Eliminar tu cuenta no cancela una suscripción Premium: cancélala antes, desde el enlace de tu recibo de Stripe, o escríbenos.';

  @override
  String get authDeleteAccountTitle => '¿Eliminar tu cuenta?';

  @override
  String get authDeleteAccountUnfinished =>
      'Los datos en la nube aún se están eliminando. Inténtalo de nuevo en un minuto para terminar.';

  @override
  String get authDeleteAccountUnlinked =>
      'Se eliminó tu cuenta y se desvinculó del perfil';

  @override
  String authDeleteDevice(String device) {
    return 'Eliminar $device';
  }

  @override
  String authDeviceCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dispositivos',
      one: '1 dispositivo',
    );
    return '$_temp0';
  }

  @override
  String get authFeedback => 'Comentarios';

  @override
  String get authFeedbackIntro =>
      'Mensajes de los miembros desde la pestaña Ayuda, los más recientes primero. Tus respuestas aparecen allí.';

  @override
  String authFeedbackLoadFailed(String error) {
    return 'No se pudieron cargar los comentarios ($error).';
  }

  @override
  String get authHaveCode =>
      '¿Tienes un código de tu otra cuenta? Introdúcelo para vincular esta a ella.';

  @override
  String get authHidden => 'oculto';

  @override
  String authHiddenCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dispositivos ocultos',
      one: '1 dispositivo oculto',
    );
    return '$_temp0';
  }

  @override
  String get authHiddenTooltip =>
      'Supera el límite de dispositivos del plan: no se sincroniza, y sus eventos se ocultan aquí';

  @override
  String authHideDevice(String device) {
    return 'Ocultar los eventos de $device';
  }

  @override
  String get authJoin => 'Únete a Presence';

  @override
  String get authJoinFree => 'Unirse gratis';

  @override
  String get authJoinFreeFailed =>
      'No se pudo unir ahora. Inténtalo de nuevo en un momento.';

  @override
  String authJoinFreeText(String email) {
    return '$email aún no es miembro de Presence. Únete gratis para usarlo en este dispositivo.';
  }

  @override
  String get authLeader => 'líder';

  @override
  String get authLeaderTooltip =>
      'El streamer líder del perfil: el único que transmite a la nube. Los demás esperan, y uno toma su lugar cuando lleva una hora sin conexión.';

  @override
  String get authLinkAnother => 'Vincular otra cuenta';

  @override
  String get authLinkCode => 'Código de vínculo';

  @override
  String get authLinkCodeHelp =>
      'En menos de 10 minutos, inicia sesión con la otra cuenta de Google e introduce este código en Cuentas vinculadas.';

  @override
  String get authLinkCodeWrong =>
      'Ese código es incorrecto, ya se usó o caducó.';

  @override
  String get authLinkConflict =>
      'Esta cuenta no se puede vincular: tiene sus propios datos en la nube u otras cuentas vinculadas.';

  @override
  String get authLinkNoBackup =>
      'La copia en la nube no está configurada, así que no se pueden vincular cuentas.';

  @override
  String get authLinkOtherAccount =>
      '¿Tienes acceso con otra cuenta de Google? Vincúlala';

  @override
  String get authLinkThis => 'Vincular esta cuenta';

  @override
  String get authLinkTooMany =>
      'Demasiados intentos. Espera un minuto y vuelve a intentarlo.';

  @override
  String get authLinkedAccounts => 'Cuentas vinculadas';

  @override
  String get authLinkedIntro =>
      'Cualquiera de estas cuentas de Google accede a los mismos clips y eventos.';

  @override
  String authLinkedTo(String owner) {
    return 'Vinculada a $owner.';
  }

  @override
  String get authLinkedToProfile => 'Vinculada al perfil.';

  @override
  String get authNoEvents => 'Sin eventos';

  @override
  String get authNoFeedback => 'Aún no hay comentarios.';

  @override
  String get authNoRoles => 'Aún no hay roles';

  @override
  String get authNoVerifiedEmail =>
      'Esta cuenta no tiene un correo verificado.';

  @override
  String get authNotSignedIn => 'No has iniciado sesión.';

  @override
  String authOpenHost(String host) {
    return 'Abrir $host';
  }

  @override
  String get authOsUnknown => 'Sistema operativo desconocido';

  @override
  String get authOwner => 'Propietaria';

  @override
  String get authPaymentsDefaults =>
      'Aún sin guardar: son los enlaces del despliegue.';

  @override
  String get authPaymentsIntro =>
      'Los enlaces de pago de Stripe con los que los miembros gratuitos pasan a Premium, y los miembros a Pro. Deja uno vacío para no ofrecer ese plan.';

  @override
  String get authPaymentsInvalid => 'Vacío, o un enlace https de stripe.com';

  @override
  String get authPaymentsMonthly => 'Enlace del plan mensual';

  @override
  String get authPaymentsProMonthly => 'Enlace del plan Pro mensual';

  @override
  String get authPaymentsProYearly => 'Enlace del plan Pro anual';

  @override
  String get authPaymentsSave => 'Guardar enlaces';

  @override
  String authPaymentsSaveFailed(String error) {
    return 'No se pudieron guardar los enlaces ($error)';
  }

  @override
  String get authPaymentsSaved => 'Enlaces de pago guardados';

  @override
  String get authPaymentsTitle => 'Pagos';

  @override
  String get authPaymentsUnavailable => 'La API de pagos no respondió.';

  @override
  String get authPaymentsYearly => 'Enlace del plan anual';

  @override
  String get authPlanFree => 'Gratis';

  @override
  String authPlanFreeText(int free, int premium, int pro) {
    return 'Gratis: cada dispositivo guarda sus eventos, y hasta $free dispositivos los comparten cada 15 minutos. Premium los sincroniza al instante, con copia en la nube y hasta $premium dispositivos: US\$20 al mes, la primera semana gratis. Pro: hasta $pro dispositivos.';
  }

  @override
  String get authPlanPremium => 'Premium';

  @override
  String authPlanPremiumProText(int limit, int pro) {
    return 'Premium: copia en la nube y hasta $limit dispositivos sincronizados. Pro: hasta $pro dispositivos.';
  }

  @override
  String authPlanPremiumText(int limit) {
    return 'Premium: copia en la nube y hasta $limit dispositivos sincronizados.';
  }

  @override
  String get authPlanPro => 'Pro';

  @override
  String authPlanProText(int limit) {
    return 'Pro: copia en la nube y hasta $limit dispositivos sincronizados.';
  }

  @override
  String get authPremiumMonthly => 'Premium mensual';

  @override
  String get authPremiumYearly => 'Premium anual';

  @override
  String get authProMonthly => 'Pro mensual';

  @override
  String get authProYearly => 'Pro anual';

  @override
  String get authProfile => 'Perfil';

  @override
  String get authProviderNotConfigured =>
      'Este inicio de sesión aún no está configurado en el servidor.';

  @override
  String get authRbacrText =>
      'Los códigos de cupón y el modo de mantenimiento se gestionan en rbacr, que guarda todos los roles. Los miembros canjean códigos en la hoja Suscribirse.';

  @override
  String get authRedeem => 'Canjear';

  @override
  String get authReload => 'Recargar';

  @override
  String authReplyFailed(String email, String error) {
    return 'No se pudo responder a $email ($error)';
  }

  @override
  String authRequestFailed(int status) {
    return 'La solicitud falló (HTTP $status).';
  }

  @override
  String get authRetry => 'Reintentar';

  @override
  String get authRoleRoot => 'Root';

  @override
  String authRolesSemantics(String roles) {
    return 'Roles: $roles';
  }

  @override
  String get authSessionEnded => 'Tu sesión terminó. Vuelve a iniciar sesión.';

  @override
  String get authSessionRefused => 'Presence no aceptó este inicio de sesión.';

  @override
  String get authSessionUnreachable =>
      'No se pudo conectar con Presence. Inténtalo de nuevo.';

  @override
  String authShowDevice(String device) {
    return 'Mostrar los eventos de $device';
  }

  @override
  String get authSignIn => 'Iniciar sesión';

  @override
  String get authSignInToPresence => 'Inicia sesión en Presence';

  @override
  String get authSignInWithApple => 'Iniciar sesión con Apple';

  @override
  String get authSignInWithGoogle => 'Iniciar sesión con Google';

  @override
  String get authSignOut => 'Cerrar sesión';

  @override
  String get authSignUp => 'Suscribirse';

  @override
  String authSignedInAs(String identity) {
    return 'Sesión iniciada como $identity';
  }

  @override
  String authSomethingWrong(String error) {
    return 'Algo salió mal ($error).';
  }

  @override
  String get authStreamerBody =>
      'Pega esto en una terminal de una Raspberry Pi con cámara (Raspberry Pi OS, 32 o 64 bits), incluso sin pantalla. Instala el streamer de Presence como un nuevo dispositivo de este perfil, que graba desde cada arranque y guarda los clips con personas y animales. Nadie inicia sesión en la Pi.';

  @override
  String get authStreamerCopied => 'Comando copiado: pégalo en la Raspberry Pi';

  @override
  String get authStreamerCopy => 'Copiar comando';

  @override
  String get authStreamerCreate => 'Crear comando';

  @override
  String authStreamerFailed(String error) {
    return 'No se pudo crear el comando ($error)';
  }

  @override
  String get authStreamerKeyOnce =>
      'Contiene la clave de este dispositivo, que solo se muestra ahora: mantenla privada. Borrar el dispositivo lo detiene; crear otro comando crea otro dispositivo.';

  @override
  String get authStreamerTitle => 'Transmitir desde una Raspberry Pi';

  @override
  String get authSubscribe => 'Suscribirse';

  @override
  String get authSubscribeButton => 'Suscribirse en nu01.com';

  @override
  String authSubscribeText(String email) {
    return '$email aún no tiene acceso a Presence. Suscríbete en nu01.com: gratis, o Premium para copia en la nube y más dispositivos. Luego vuelve a comprobarlo aquí.';
  }

  @override
  String get authSyncFree =>
      'Cada dispositivo guarda sus eventos; tus dispositivos los comparten cada 15 minutos (Premium: al instante)';

  @override
  String get authThisAccount => 'Esta cuenta';

  @override
  String get authThisDevice => 'este dispositivo';

  @override
  String get authThisDeviceHidden => 'Este dispositivo no se sincroniza';

  @override
  String get authUnavailable => 'No se puede iniciar sesión.';

  @override
  String get authUnlink => 'Desvincular';

  @override
  String authUnlinked(String email) {
    return 'Se desvinculó $email.';
  }

  @override
  String get authUpgrade => 'Mejorar';

  @override
  String get authUpgradePremium => 'Pasar a Premium';

  @override
  String get authUploadFailed => 'Error al subir';

  @override
  String get authUploading => 'Subiendo…';

  @override
  String authVoucherDiscount(int discount) {
    return 'Ese código da un $discount% de descuento. Aún no se puede pagar el resto, así que no te da acceso.';
  }

  @override
  String get authVoucherFailed => 'No se pudo canjear el código.';

  @override
  String authVoucherFailedDetail(String error) {
    return 'No se pudo canjear el código ($error).';
  }

  @override
  String get authVoucherInvalid =>
      'Ese código no es válido, caducó o ya se usó.';

  @override
  String get authVoucherLabel => 'Código de cupón';

  @override
  String get authVoucherPayment =>
      'Ese código requiere un pago, que aún no está disponible, así que no te da acceso.';

  @override
  String get authVoucherPrompt =>
      '¿Tienes un código de cupón? Canjéalo para entrar al instante.';

  @override
  String get authVoucherTooMany =>
      'Demasiados intentos. Espera un rato y vuelve a intentarlo.';

  @override
  String get authVouchersTitle => 'Cupones y mantenimiento';

  @override
  String get authYourAccount => 'Tu cuenta';

  @override
  String get blinkAbout =>
      'Un streamer Linux tuyo (una Raspberry Pi) trae los clips de tus cámaras Blink: cada cámara es un dispositivo, y sus clips con una persona o un animal se vuelven eventos.';

  @override
  String get blinkConnect => 'Conectar';

  @override
  String blinkConnected(String account) {
    return 'Conectado a Blink como $account. Sus cámaras:';
  }

  @override
  String get blinkDisconnect => 'Desconectar';

  @override
  String get blinkEmail => 'Correo de la cuenta Blink';

  @override
  String blinkError(String error) {
    return 'Blink: $error';
  }

  @override
  String get blinkInstalling =>
      'Instalando el soporte de Blink en el streamer (una vez)…';

  @override
  String blinkLastFetch(String time) {
    return 'Clips traídos por última vez a las $time.';
  }

  @override
  String get blinkLoggingIn => 'Iniciando sesión en Blink…';

  @override
  String get blinkNoCameras => 'Aún no hay cámaras.';

  @override
  String get blinkNoStreamer =>
      'Configura primero un streamer en una Raspberry Pi (Perfil › Transmitir desde una Raspberry Pi); trae los clips de las cámaras Blink.';

  @override
  String get blinkNotSent =>
      'No se pudo enviar: la clave del streamer aún no está aquí, o la sincronización está apagada. Inténtalo en un minuto.';

  @override
  String get blinkOff => 'Sin conexión a Blink.';

  @override
  String get blinkPassword => 'Contraseña de Blink';

  @override
  String get blinkPasswordNote =>
      'Sellada con la clave del streamer (solo tus dispositivos la abren) y borrada cuando inicia sesión; solo guarda el token de Blink.';

  @override
  String get blinkPin => 'PIN';

  @override
  String blinkPinRequired(String account) {
    return 'Blink envió un PIN al correo o teléfono de $account: escríbelo aquí.';
  }

  @override
  String get blinkSendPin => 'Enviar PIN';

  @override
  String get blinkStreamer => 'El streamer que los trae';

  @override
  String blinkWaiting(String device) {
    return 'Enviado a $device; revisa cada 30 s…';
  }

  @override
  String cameraAgeDays(int days) {
    return 'hace $days d';
  }

  @override
  String cameraAgeHours(int hours) {
    return 'hace $hours h';
  }

  @override
  String get cameraAgeJustNow => 'ahora mismo';

  @override
  String cameraAgeMinutes(int minutes) {
    return 'hace $minutes min';
  }

  @override
  String cameraAgeSeconds(int seconds) {
    return 'hace $seconds s';
  }

  @override
  String get cameraAskedFreshGrab => 'Se pidió una imagen nueva';

  @override
  String get cameraClip => 'Clip';

  @override
  String get cameraClipArchived =>
      'Archivado: este video está en almacenamiento en frío';

  @override
  String get cameraClipCameraOff => 'Cámara apagada';

  @override
  String cameraClipCountdown(String time) {
    return 'Clip · $time';
  }

  @override
  String get cameraClipLoadFailed => 'No se pudo cargar este clip';

  @override
  String cameraClipNextIn(String countdown) {
    return 'Próximo clip automático en $countdown';
  }

  @override
  String get cameraClipNoCamera => 'Sin cámara';

  @override
  String get cameraClipNotReady => 'La cámara no está lista';

  @override
  String get cameraClipPreview => 'Vista previa';

  @override
  String get cameraClipReady => 'Listo';

  @override
  String cameraClipRecordingNext(int seconds) {
    return 'Grabando los próximos $seconds s…';
  }

  @override
  String get cameraClipSaving => 'Guardando clip…';

  @override
  String cameraClipSavingNext(String next) {
    return 'Guardando clip… $next';
  }

  @override
  String get cameraClipStarting => 'Iniciando la cámara…';

  @override
  String get cameraClipUnavailable => 'Cámara no disponible';

  @override
  String cameraCouldNotOpen(String reason) {
    return 'No se pudo abrir la cámara\n$reason';
  }

  @override
  String get cameraErrorBlocked =>
      'El acceso a la cámara está bloqueado para este sitio. Permite la cámara en los ajustes del sitio del navegador y reintenta.';

  @override
  String get cameraErrorDenied =>
      'Se denegó el permiso de cámara. Permítelo en Ajustes.';

  @override
  String get cameraErrorGeneric => 'Algo salió mal al iniciar la cámara.';

  @override
  String get cameraErrorInUse =>
      'Otra app está usando la cámara, o no pudo iniciarse. Cierra las apps que la usan y reintenta.';

  @override
  String get cameraErrorInsecure =>
      'La cámara solo funciona en una página segura. Abre Presence por HTTPS.';

  @override
  String get cameraErrorNoneFound =>
      'No se encontró ninguna cámara. Conecta una y reintenta.';

  @override
  String get cameraErrorStopped =>
      'La cámara se detuvo (desconectada o retirada)';

  @override
  String get cameraFlip => 'Cambiar cámara';

  @override
  String get cameraLive => 'en vivo';

  @override
  String get cameraModeAll => 'Todos los dispositivos';

  @override
  String get cameraModeAllHint => 'Todos los dispositivos en cuadrícula';

  @override
  String get cameraModeMenu => 'Modo de la cámara';

  @override
  String get cameraModeNormal => 'Esta cámara';

  @override
  String get cameraModeNormalHint => 'Pantalla completa';

  @override
  String get cameraModeStopped => 'Detenido';

  @override
  String get cameraModeStoppedHint => 'Sin capturar ni sincronizar';

  @override
  String get cameraModeUnattended => 'Desatendido';

  @override
  String get cameraModeUnattendedHint => 'Pantalla apagada, sigue capturando';

  @override
  String get cameraNight => 'Noche';

  @override
  String get cameraNightTooltip =>
      'Modo noche: lo más brillante posible, e iluminado mientras graba un clip';

  @override
  String get cameraNotFound => 'No se encontró ninguna cámara';

  @override
  String get cameraOffMessage =>
      'Cámara apagada\nNo se graba nada hasta que la enciendas.';

  @override
  String get cameraRetry => 'Reintentar';

  @override
  String get cameraThisDevice => 'Este dispositivo';

  @override
  String get cameraTurnOn => 'Encender';

  @override
  String get clipAuto => 'Auto';

  @override
  String get clipAutoAllTagged =>
      'Todos los sujetos ya nombrados están en este clip.';

  @override
  String clipAutoCloudFailed(String subjects) {
    return '$subjects El reconocimiento en la nube no respondió (razas y pelajes); inténtalo de nuevo.';
  }

  @override
  String get clipAutoDeferred =>
      'El teléfono tiene poca memoria: inténtalo de nuevo en un momento.';

  @override
  String get clipAutoFailed =>
      'No se pudo ejecutar el reconocimiento; inténtalo de nuevo.';

  @override
  String clipAutoFound(String names) {
    return 'Encontrado: $names.';
  }

  @override
  String get clipAutoLooking => 'Buscando los sujetos ya nombrados…';

  @override
  String get clipAutoNoReferences =>
      'Aún no hay sujetos que buscar: primero nombra a alguien en otro clip.';

  @override
  String get clipAutoNone => 'No se reconoció ningún sujeto.';

  @override
  String clipAutoNotSureMany(String names) {
    return 'No hay certeza sobre $names: responde las preguntas en los eventos.';
  }

  @override
  String clipAutoNotSureOne(String names, String name) {
    return 'No hay certeza sobre $names: responde \"¿Es $name?\" en los eventos.';
  }

  @override
  String clipAutoTags(String subjects, String tags) {
    return '$subjects Etiquetas: $tags.';
  }

  @override
  String get clipAutoTooltip =>
      'Busca los sujetos ya nombrados y etiqueta lo que se ve, en este dispositivo';

  @override
  String get clipAutoUnavailable => 'Aún no disponible en este dispositivo';

  @override
  String get clipAutoUnsupported =>
      'El reconocimiento aún no está disponible en este dispositivo.';

  @override
  String get clipAutoWaiting => 'Esperando a que termine de grabarse el clip…';

  @override
  String get clipCancel => 'Cancelar';

  @override
  String get clipClose => 'Cerrar';

  @override
  String get clipDone => 'Listo';

  @override
  String get clipFrameTagLabel =>
      'Fotograma para nombrar sujetos: haz clic en una persona o mascota para nombrarla';

  @override
  String get clipGrabFailed =>
      'No se pudo capturar este fotograma; inténtalo de nuevo';

  @override
  String clipIdentifyHint(String label) {
    return '$label: haz clic en el video para nombrarlo, o prueba Auto.';
  }

  @override
  String get clipNameAdd => 'Añadir';

  @override
  String get clipNameFrameHint => 'Nombra a alguien en este fotograma';

  @override
  String get clipNameHint => 'Nombre';

  @override
  String get clipNameMore => 'Nombrar más sujetos en este fotograma';

  @override
  String get clipNameSpotHint => '¿Quién está en el círculo?';

  @override
  String get clipNameSubject => 'Nombrar sujeto';

  @override
  String clipNamesAnd(String first, String last) {
    return '$first y $last';
  }

  @override
  String get clipNoSubjects =>
      'Aún no hay sujetos. Haz clic en una persona o mascota del video para nombrarla.';

  @override
  String get clipNoTags => 'Sin etiquetas: no se vio nada en este clip.';

  @override
  String get clipNoTagsYet =>
      'Aún no hay etiquetas. Lo que se vea en el clip, como una botella o una bicicleta, aparece aquí tras analizarlo.';

  @override
  String get clipNoTagsYetTryAuto =>
      'Aún no hay etiquetas. Lo que se vea en el clip, como una botella o una bicicleta, aparece aquí tras analizarlo (prueba Auto).';

  @override
  String get clipNoVideo => 'No se grabó video';

  @override
  String get clipNotRecordedClosed =>
      'No grabado: la app se cerró mientras grababa';

  @override
  String clipNotSaved(String status, String error) {
    return '$status · no guardado: $error';
  }

  @override
  String get clipPlay => 'Reproducir el clip';

  @override
  String clipPreviousOnly(int before, int after) {
    return 'Solo los $before s anteriores: la app se cerró antes de grabar los $after s siguientes';
  }

  @override
  String clipPreviousReady(int before, int after) {
    return '$before s anteriores listos · grabando $after s siguientes…';
  }

  @override
  String clipReady(int seconds) {
    return 'Clip de $seconds s listo';
  }

  @override
  String get clipRecordingElsewhere => 'Grabando en otro dispositivo…';

  @override
  String get clipRecordingFailed => 'La grabación falló';

  @override
  String clipRecordingNext(int after) {
    return 'Grabando $after s siguientes…';
  }

  @override
  String get clipRemoveSubject => 'Quitar sujeto';

  @override
  String clipRemoveSubjectFromEvent(String label) {
    return 'Quitar el sujeto $label de este evento';
  }

  @override
  String clipRemoveTagFromEvent(String label) {
    return 'Quitar la etiqueta $label de este evento';
  }

  @override
  String get clipRenameSubject => 'Renombrar sujeto';

  @override
  String get clipSave => 'Guardar';

  @override
  String clipSavingPrevious(int before) {
    return 'Guardando $before s anteriores…';
  }

  @override
  String clipShowAt(String time) {
    return 'Ver en $time';
  }

  @override
  String get clipShowEveryEvent => 'Ver todos los eventos';

  @override
  String get clipShowEveryHold =>
      'Ver todos los eventos (mantén pulsado para renombrar)';

  @override
  String clipShowOnlyHold(String name) {
    return 'Ver solo eventos con $name (mantén pulsado para renombrar)';
  }

  @override
  String clipShowOnlyWith(String label) {
    return 'Ver solo eventos con $label';
  }

  @override
  String get clipSubjects => 'Sujetos';

  @override
  String clipTagHint(String time) {
    return 'Haz clic donde está una persona o mascota en la imagen y escribe su nombre abajo; o solo escribe el nombre para este fotograma (en $time).';
  }

  @override
  String get clipTags => 'Etiquetas';

  @override
  String get clipUnsupported =>
      'Los clips de video no son compatibles con esta plataforma';

  @override
  String get clipWhoIsThis => '¿Quién es?';

  @override
  String get connectivityAllGood =>
      'En línea · sincronización en vivo conectada';

  @override
  String get connectivityChecking => 'Comprobando la conexión…';

  @override
  String get connectivityCloudFailed => 'Falló la sincronización en la nube';

  @override
  String get connectivityCloudNotSet =>
      'La sincronización en la nube no está configurada en esta versión';

  @override
  String get connectivityCloudOn => 'Sincronización en la nube activa';

  @override
  String get connectivityCloudOneSide =>
      'La sincronización en la nube está configurada solo de un lado';

  @override
  String get connectivityFree =>
      'Free: los dispositivos comparten eventos cada 15 min';

  @override
  String connectivityLabel(String headline) {
    return 'Conectividad: $headline';
  }

  @override
  String get connectivityLiveConnected => 'Sincronización en vivo conectada';

  @override
  String get connectivityLiveConnecting =>
      'Conectando la sincronización en vivo…';

  @override
  String get connectivityLiveFailed => 'Falló la sincronización en vivo';

  @override
  String connectivityLiveIdle(String next) {
    return 'Sincronización en vivo en espera · próxima en $next';
  }

  @override
  String get connectivityLiveNotSet =>
      'La sincronización en vivo no está configurada en esta versión';

  @override
  String get connectivityLiveOff =>
      'La sincronización en vivo está desactivada';

  @override
  String get connectivityLiveOnceSynced =>
      'La sincronización en vivo se conecta tras sincronizar';

  @override
  String get connectivityNote =>
      'Los demás dispositivos ven este en vivo solo mientras la sincronización en vivo está conectada.';

  @override
  String get connectivityOffline =>
      'Sin conexión: no se puede contactar con el servidor';

  @override
  String get connectivityOnline => 'En línea';

  @override
  String connectivityPresenceAnswered(String since) {
    return 'En vivo — respondió $since';
  }

  @override
  String connectivityPresenceLastSeen(String since, String unavailable) {
    return 'Visto por última vez $since$unavailable';
  }

  @override
  String connectivityPresenceNever(String unavailable) {
    return 'Nunca visto$unavailable';
  }

  @override
  String get connectivityPresenceThisLive =>
      'En vivo — este dispositivo, conectado a la sincronización en vivo';

  @override
  String get connectivityPresenceThisNotConnected =>
      'Este dispositivo — sin conexión a la sincronización en vivo ahora';

  @override
  String get connectivityPresenceThisUnavailable =>
      'Este dispositivo — estado en vivo no disponible';

  @override
  String get connectivityPresenceUnavailable =>
      ' · estado en vivo no disponible';

  @override
  String connectivityThisDevice(String headline) {
    return 'Este dispositivo — $headline';
  }

  @override
  String get consentAgree => 'Acepto';

  @override
  String get consentBiometricsDetail =>
      'Según el RGPD, los rostros usados para identificar personas, como al nombrarlas en clips, requieren cuidado: consentimiento claro, custodia segura y eliminación a petición.';

  @override
  String get consentBiometricsTitle =>
      'Los rostros son datos biométricos, y soy responsable.';

  @override
  String get consentFootnote =>
      'Se pregunta una vez en este dispositivo. No es asesoramiento legal.';

  @override
  String get consentIntro => 'Al continuar, confirmas:';

  @override
  String get consentRightDetail =>
      'Soy dueño o administro este lugar, o tengo permiso, y las personas que puedan ser grabadas lo saben.';

  @override
  String get consentRightTitle => 'Tengo derecho a grabar aquí.';

  @override
  String get consentTitle => 'Antes de que Presence empiece a grabar';

  @override
  String get devModeTooltip =>
      'Modo de desarrollo: el inicio de sesión no está configurado, así que todo está abierto a todos.';

  @override
  String devModeTooltipVersion(String version) {
    return 'Modo de desarrollo, versión $version: el inicio de sesión no está configurado, así que todo está abierto a todos.';
  }

  @override
  String get eventAlreadyDeleted => 'El evento ya estaba eliminado';

  @override
  String get eventCancel => 'Cancelar';

  @override
  String get eventCloudArchived =>
      'Archivado en la nube (no en este dispositivo)';

  @override
  String get eventCloudColdStorage =>
      'Su grabación está en almacenamiento en frío: no se puede reproducir desde la nube';

  @override
  String get eventCloudDelete => 'Borrar';

  @override
  String get eventCloudDeleteBody =>
      'Su grabación, miniatura y etiquetas se borran de la nube. Este dispositivo no lo volverá a subir a menos que lo subas tú.';

  @override
  String get eventCloudDeleteFailed => 'No se pudo borrar de la nube';

  @override
  String get eventCloudDeleteOnlyCopy =>
      'Este dispositivo no tiene una copia completa: salvo que otro la tenga, se pierde para siempre.';

  @override
  String get eventCloudDeleteTitle => '¿Borrar de la nube?';

  @override
  String get eventCloudDeleted => 'Borrado de la nube';

  @override
  String get eventCloudNotSynced => 'No está en la nube';

  @override
  String get eventCloudPutFailed =>
      'No se pudo subir a la nube: hace falta un perfil premium y una copia completa en este dispositivo.';

  @override
  String get eventCloudPutting => 'Subiéndolo a la nube…';

  @override
  String get eventCloudSynced => 'En la nube';

  @override
  String get eventCloudTapToDelete => 'Toca para borrarlo de la nube';

  @override
  String get eventCloudTapToPut => 'Toca para subirlo a la nube';

  @override
  String eventCopies(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count copias',
      one: '$count copia',
    );
    return '$_temp0';
  }

  @override
  String get eventCopiesCloud => 'Nube';

  @override
  String get eventCopiesCloudColdStorage => 'Nube (almacenamiento en frío)';

  @override
  String get eventCopiesLiveOff =>
      'La sincronización en vivo está desactivada: no se conocen las copias de otros dispositivos';

  @override
  String get eventCopiesNone => 'No se conoce ninguna copia';

  @override
  String get eventCopiesNotSynced => 'Sin sincronizar';

  @override
  String eventCopiesOnDevices(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'En $count dispositivos',
      one: 'En 1 dispositivo',
      zero: 'En ningún dispositivo',
    );
    return '$_temp0';
  }

  @override
  String get eventCopiesShareFailed =>
      'No se pudo llegar a los otros dispositivos: la sincronización en vivo está apagada o sin conexión';

  @override
  String get eventCopiesSharing =>
      'Se pidió a los otros dispositivos que tomen una copia';

  @override
  String get eventCopiesTapToShare =>
      'Toca para sincronizar una copia en todos los dispositivos';

  @override
  String get eventCopiesThisDevice => 'Este dispositivo';

  @override
  String get eventDelete => 'Eliminar evento';

  @override
  String get eventDeleteClipNote =>
      'Su clip queda en la nube hasta que caduque.';

  @override
  String get eventDeleteConfirm => 'Eliminar';

  @override
  String get eventDeleteFailed => 'No se pudo eliminar el evento';

  @override
  String get eventDeleteMessage =>
      '¿Eliminar este evento? Se ocultará en todos los dispositivos.';

  @override
  String get eventDeleteTitle => '¿Eliminar evento?';

  @override
  String get eventDeletedEverywhere =>
      'Evento eliminado en todos los dispositivos';

  @override
  String get eventDetailCaptureAll => 'Cada dispositivo graba un clip';

  @override
  String get eventDetailClipMissing => 'Falta la grabación del clip';

  @override
  String eventDetailSure(int percent) {
    return '$percent % de certeza';
  }

  @override
  String get eventDevice => 'Dispositivo';

  @override
  String get eventDeviceUnknown => 'Dispositivo desconocido';

  @override
  String eventFlagIdentify(String label) {
    return '$label · Identificar';
  }

  @override
  String get eventFlagUnidentified => 'Sujeto sin identificar';

  @override
  String get eventFlagUnidentifiedTooltip =>
      'Sujeto sin identificar — identificar';

  @override
  String get eventLocationDevice => 'Posición del dispositivo';

  @override
  String get eventLocationMap => 'Marcada en el mapa';

  @override
  String get eventLocationPinned => 'Fijada';

  @override
  String get eventNoLocation => 'Este evento no tiene ubicación';

  @override
  String get eventOsUnknown => 'Sistema operativo desconocido';

  @override
  String get eventRecognitionComplete => 'El reconocimiento se completó';

  @override
  String eventRecognitionFailed(String reason) {
    return 'El reconocimiento falló: $reason';
  }

  @override
  String get eventRecognitionNotRun => 'El reconocimiento no se ha hecho';

  @override
  String get eventRecognitionPartial => 'El reconocimiento se hizo en parte';

  @override
  String get eventRecognitionRerunning => 'Ejecutando el reconocimiento…';

  @override
  String get eventRecognitionTapToRerun =>
      'Toca para ejecutar el reconocimiento';

  @override
  String get eventSubjectsAllTagged =>
      'Personas y mascotas: todos los conocidos ya están nombrados';

  @override
  String eventSubjectsFound(String names) {
    return 'Personas y mascotas: $names';
  }

  @override
  String get eventSubjectsNoReferences =>
      'Personas y mascotas: aún no hay nadie nombrado que buscar';

  @override
  String get eventSubjectsNone =>
      'Personas y mascotas: buscadas, nadie reconocido';

  @override
  String get eventSubjectsNotSearched => 'Personas y mascotas: sin buscar';

  @override
  String get eventSuggestionClipMissing => 'Falta el clip';

  @override
  String get eventSuggestionNo => 'No';

  @override
  String eventSuggestionNot(String name) {
    return 'No es $name';
  }

  @override
  String eventSuggestionTagged(String name) {
    return 'Etiquetado como $name';
  }

  @override
  String eventSuggestionYes(String name) {
    return 'Sí, es $name';
  }

  @override
  String eventTagsFound(String labels) {
    return 'Etiquetas de objetos: $labels';
  }

  @override
  String get eventTagsNone => 'Etiquetas de objetos: buscadas, no se vio nada';

  @override
  String get eventTagsNotSearched => 'Etiquetas de objetos: sin buscar';

  @override
  String get eventThisDevice => 'este dispositivo';

  @override
  String get eventTitleAppStarted => 'Aplicación iniciada';

  @override
  String get eventTitleCaptureAll => 'Capturar todo';

  @override
  String get eventTitleClipRequested => 'Clip solicitado';

  @override
  String get eventTitleConsentGiven => 'Consentimiento de grabación dado';

  @override
  String get eventTitleGeneric => 'Evento';

  @override
  String eventTitleIsThis(String name) {
    return '¿Es $name?';
  }

  @override
  String get eventTitleMotion => 'Movimiento detectado';

  @override
  String get eventTitleScheduled => 'Clip programado';

  @override
  String get eventTitleSignedIn => 'Sesión iniciada';

  @override
  String get eventTitleSignedOut => 'Sesión cerrada';

  @override
  String get eventTitleStartup => 'Clip de inicio';

  @override
  String get eventWhere => 'Dónde';

  @override
  String eventsCountTooltip(int shown, int all) {
    return '$shown de $all eventos mostrados';
  }

  @override
  String get eventsDeleteAll => 'Eliminar los eventos mostrados';

  @override
  String get eventsDeleteAllClipNote =>
      'Sus clips quedan en la nube hasta que caduquen.';

  @override
  String get eventsDeleteAllMessage =>
      '¿Eliminar todos los eventos mostrados? Se ocultarán en todos los dispositivos.';

  @override
  String eventsDeleteAllTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '¿Eliminar $count eventos?',
      one: '¿Eliminar 1 evento?',
    );
    return '$_temp0';
  }

  @override
  String get eventsDeleteFailed => 'No se pudieron eliminar los eventos';

  @override
  String eventsDeletedEverywhere(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count eventos eliminados en todos los dispositivos',
      one: '1 evento eliminado en todos los dispositivos',
      zero: 'Ningún evento eliminado',
    );
    return '$_temp0';
  }

  @override
  String get eventsHideSystem => 'Ocultar eventos del sistema';

  @override
  String get eventsNoGrabs =>
      'Aún no hay capturas: los eventos del sistema están ocultos';

  @override
  String eventsNoMatch(String query) {
    return 'Ningún evento coincide con \"$query\"';
  }

  @override
  String get eventsNone => 'No hay eventos';

  @override
  String get eventsSearch => 'Buscar eventos';

  @override
  String get eventsSearchClear => 'Borrar búsqueda';

  @override
  String get eventsShowDevice => 'Ver los eventos de este dispositivo';

  @override
  String get eventsShowEveryDevice =>
      'Ver los eventos de todos los dispositivos';

  @override
  String get eventsShowSystem => 'Mostrar eventos del sistema';

  @override
  String get feedbackAdmin => 'Admin';

  @override
  String get feedbackAnswered => 'Respondido';

  @override
  String get feedbackAwaitingReply => 'Esperando respuesta';

  @override
  String get feedbackMember => 'Miembro';

  @override
  String get feedbackReply => 'Responder';

  @override
  String feedbackSendFailed(String error) {
    return 'No se pudo enviar ($error).';
  }

  @override
  String get feedbackSentTooMuch => 'Has enviado mucho hoy. Inténtalo mañana.';

  @override
  String get feedbackTeam => 'Equipo de Presence';

  @override
  String get feedbackTooManyTries => 'Demasiados intentos. Espera un minuto.';

  @override
  String get feedbackYou => 'Tú';

  @override
  String get goproAbout =>
      'Un streamer Linux tuyo (una Raspberry Pi) trae los videos nuevos de tus cámaras GoPro por su red: cada cámara es un dispositivo, y sus videos con una persona o un animal se vuelven eventos. Una GoPro HERO9 o más nueva, en la red de casa (HERO12 o más nueva), conectada por USB, o en su propio Wi-Fi.';

  @override
  String get goproAdd => 'Agregar cámara';

  @override
  String get goproAddress => 'Dirección de la cámara';

  @override
  String get goproAddressHelp =>
      'Su dirección IP: en la red de casa, la que muestra la app GoPro Quik; por USB 172.2x.1yz.51; en el Wi-Fi de la cámara 10.5.5.9.';

  @override
  String goproCameraError(String error) {
    return 'No se pueden traer: $error';
  }

  @override
  String get goproCameras => 'Sus cámaras GoPro:';

  @override
  String get goproChecking => 'Conectando con la cámara…';

  @override
  String goproError(String error) {
    return 'GoPro: $error';
  }

  @override
  String goproLastFetch(String time) {
    return 'Videos traídos por última vez a las $time.';
  }

  @override
  String get goproName => 'Nombre de la cámara';

  @override
  String get goproNoStreamer =>
      'Configura primero un streamer en una Raspberry Pi (Perfil › Transmitir desde una Raspberry Pi); trae los videos de las cámaras GoPro.';

  @override
  String get goproNone => 'Aún no hay cámaras GoPro.';

  @override
  String get goproNotSent =>
      'No se pudo enviar: la clave del streamer aún no está aquí, o la sincronización está apagada. Inténtalo en un minuto.';

  @override
  String get goproPassword => 'Contraseña de la cámara (solo red de casa)';

  @override
  String get goproPasswordNote =>
      'Sellada con la clave del streamer (solo tus dispositivos la abren) y borrada de la nube cuando el streamer la tiene.';

  @override
  String get goproRemove => 'Quitar';

  @override
  String get goproStreamer => 'El streamer que los trae';

  @override
  String goproWaiting(String device) {
    return 'Enviado a $device; revisa cada 30 s…';
  }

  @override
  String healthApiAnswered(String mode) {
    return 'API de autenticación: respondió (modo $mode)';
  }

  @override
  String get healthApiChecking => 'API de autenticación: comprobando';

  @override
  String healthApiUnreachable(String error) {
    return 'API de autenticación: inaccesible ($error)';
  }

  @override
  String get healthAuthApiName => 'API de autenticación';

  @override
  String get healthAwsOff => 'los eventos quedan en este dispositivo';

  @override
  String get healthAwsSet => 'AWS: configurado; sincroniza al iniciar sesión';

  @override
  String healthAwsSyncFailed(String error) {
    return 'AWS: falló la sincronización ($error)';
  }

  @override
  String get healthAwsSynced => 'AWS: sincronizado';

  @override
  String get healthAwsSyncing => 'AWS: sincronizando';

  @override
  String get healthChecking => 'Comprobando…';

  @override
  String healthChecks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count comprobaciones',
      one: '1 comprobación',
    );
    return '$_temp0';
  }

  @override
  String get healthDevicesHere => 'En los eventos de este dispositivo';

  @override
  String get healthDevicesProfile => 'En los eventos del perfil';

  @override
  String healthDevicesSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dispositivos en los eventos',
      one: '1 dispositivo en los eventos',
    );
    return '$_temp0';
  }

  @override
  String get healthDevicesTitle => 'Dispositivos';

  @override
  String healthDevicesTooltip(String what) {
    return '$what, aquí y sincronizados desde la nube';
  }

  @override
  String healthLastUpdate(String time) {
    return 'Última actualización $time';
  }

  @override
  String healthLiveConnected(String counts) {
    return 'En vivo: conectado ($counts)';
  }

  @override
  String get healthLiveConnecting => 'En vivo: conectando';

  @override
  String healthLiveCounts(int received, int sent) {
    return '$received recibidos, $sent enviados';
  }

  @override
  String healthLiveFailed(String error) {
    return 'En vivo: falló ($error); los eventos llegan con cada sincronización';
  }

  @override
  String healthLiveIdle(String next, String mode, String counts) {
    return 'En vivo: en espera · próxima en $next ($mode; $counts)';
  }

  @override
  String get healthLiveName => 'En vivo';

  @override
  String get healthLiveNever =>
      'En vivo: desactivado (Nunca); los eventos llegan con cada sincronización (15 s)';

  @override
  String get healthLiveNotSet =>
      'En vivo: no configurado; los eventos llegan con cada sincronización (15 s)';

  @override
  String get healthLiveOff =>
      'En vivo: configurado; se conecta tras sincronizar';

  @override
  String healthMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get healthOidcOff => 'el inicio de sesión está desactivado';

  @override
  String get healthOidcSet => 'OIDC: inicio de sesión con Google configurado';

  @override
  String get healthRbacrDev =>
      'RBACR: no se usa en modo DEV (nadie inicia sesión)';

  @override
  String get healthRbacrFree =>
      'RBACR: configurado; este perfil es Free (sus dispositivos comparten eventos cada 15 min)';

  @override
  String get healthRbacrMissing =>
      'RBACR: no configurado en la API de autenticación; nadie que inicie sesión tiene un rol';

  @override
  String get healthRbacrPremium =>
      'RBACR: configurado; este perfil es Premium (copia en la nube)';

  @override
  String get healthRbacrPro =>
      'RBACR: configurado; este perfil es Pro (copia en la nube)';

  @override
  String get healthRbacrSet => 'RBACR: configurado; asigna los roles';

  @override
  String get healthRbacrUnknown =>
      'RBACR: la API de autenticación no lo indica';

  @override
  String get healthRunFailed => 'falló';

  @override
  String get healthRunPassed => 'todo correcto';

  @override
  String healthSeconds(int seconds) {
    return '$seconds s';
  }

  @override
  String healthSettingNotInBuild(String name, String off) {
    return '$name: no configurado en esta versión; $off';
  }

  @override
  String healthSettingNotSet(String name, String off) {
    return '$name: no configurado; $off';
  }

  @override
  String healthSettingOnlyApi(String name, String off) {
    return '$name: configurado en la API de autenticación pero no en esta versión; $off';
  }

  @override
  String healthSettingOnlyBuild(String name) {
    return '$name: configurado en esta versión pero no en la API de autenticación';
  }

  @override
  String get healthTapForDetails => 'Toca para ver detalles.';

  @override
  String get healthTimeline => 'Historial';

  @override
  String healthTimelineSummary(String checks, String interval) {
    return '$checks · cada $interval';
  }

  @override
  String get healthTitle => 'Estado';

  @override
  String get healthToneChecking => 'Comprobando';

  @override
  String get healthToneFailed => 'Falló';

  @override
  String get healthToneIdle => 'En espera';

  @override
  String get healthToneMismatch => 'Discrepancia';

  @override
  String get healthToneOff => 'Apagado';

  @override
  String get healthToneOk => 'OK';

  @override
  String get healthToneSyncing => 'Sincronizando';

  @override
  String get healthUnknownError => 'error desconocido';

  @override
  String get healthWarningFailed => 'Falló una comprobación de estado';

  @override
  String get helpIntro =>
      '¿Preguntas, ideas o algo no funciona? Envía un mensaje; un administrador responderá aquí.';

  @override
  String helpLoadFailed(String error) {
    return 'No se pudieron cargar los mensajes ($error).';
  }

  @override
  String get helpMessage => 'Mensaje';

  @override
  String get helpNoMessages => 'Aún no hay mensajes.';

  @override
  String get helpNotSignedIn => 'No has iniciado sesión.';

  @override
  String get helpReload => 'Recargar';

  @override
  String get helpSend => 'Enviar';

  @override
  String get helpTitle => 'Escribe al equipo de Presence';

  @override
  String homeAskedGrabs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Se pidió una imagen nueva a $count dispositivos…',
      one: 'Se pidió una imagen nueva a 1 dispositivo…',
      zero: 'Se pidió una imagen nueva a todos los dispositivos',
    );
    return '$_temp0';
  }

  @override
  String get homeBatteryCharging => 'cargando';

  @override
  String get homeBatteryFull => 'llena';

  @override
  String homeBatteryLevel(int level) {
    return 'Batería $level %';
  }

  @override
  String get homeBatteryOnBattery => 'con batería';

  @override
  String get homeBatteryPlugged => 'conectada, sin cargar';

  @override
  String homeBatteryTemperature(String temperature) {
    return 'Temperatura de la batería $temperature';
  }

  @override
  String homeBatteryTemperatureHot(String temperature) {
    return 'Temperatura de la batería $temperature, caliente';
  }

  @override
  String get homeClipAll => 'Capturar todo';

  @override
  String get homeClipManual => 'Clip iniciado';

  @override
  String get homeClipMotion => 'Movimiento detectado';

  @override
  String homeClipSaving(String started, int seconds) {
    return '$started · guardando los próximos $seconds s';
  }

  @override
  String get homeClipScheduled => 'Clip programado';

  @override
  String get homeClipStartup => 'Clip de inicio';

  @override
  String homeJoinedAccount(String email, String deviceId) {
    return 'Este dispositivo ahora es de $email: $deviceId';
  }

  @override
  String homeJoinedOpen(String deviceId) {
    return 'Presence está abierto en este dispositivo: $deviceId';
  }

  @override
  String homeMessageTapToView(String label) {
    return '$label. Toca para verlo.';
  }

  @override
  String get homeScreenOffHint =>
      'Desatendido: capturando con la pantalla apagada. Toca para activarla.';

  @override
  String homeSignInFailed(String error) {
    return 'Error al iniciar sesión: $error';
  }

  @override
  String get homeUnattendedWoken =>
      'Desatendido: se apaga 15 s después del último toque';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageLabel => 'Idioma de la aplicación';

  @override
  String get languageNote =>
      'Los nombres, las etiquetas y los ID de dispositivo se muestran tal como se escribieron.';

  @override
  String get languagePortuguese => 'Português';

  @override
  String get languageSection => 'Idioma';

  @override
  String get languageSpanish => 'Español';

  @override
  String get languageSystem => 'El mismo que el dispositivo';

  @override
  String get legalPrivacy => 'Política de privacidad';

  @override
  String get legalTerms => 'Términos del servicio';

  @override
  String get logClear => 'Borrar';

  @override
  String get logCopied => 'Registro copiado';

  @override
  String get logCopy => 'Copiar';

  @override
  String get logEmpty => 'Aún no hay registros.';

  @override
  String get logTitle => 'Registro';

  @override
  String logTitleCount(int count) {
    return 'Registro · últimos $count';
  }

  @override
  String get maintenanceBody =>
      'Volveremos pronto. Esta página se actualiza sola.';

  @override
  String get maintenanceTitle => 'Lo sentimos, Presence está en mantenimiento.';

  @override
  String get monitoringSyncAsked =>
      'Sincronizando: este dispositivo ahora, y se pidió a los demás';

  @override
  String get monitoringSyncHere =>
      'Sincronizando este dispositivo; no se pudo pedir a los demás (la sincronización en vivo está apagada o sin conexión)';

  @override
  String get monitoringSyncTooltip => 'Sincronizar todos los dispositivos';

  @override
  String get navAdmin => 'Admin';

  @override
  String get navCamera => 'Cáms';

  @override
  String get navHelp => 'Ayuda';

  @override
  String get navHelpTitle => 'Ayuda';

  @override
  String get navLog => 'Registro';

  @override
  String get navMonitoring => 'Eventos';

  @override
  String get navProfile => 'Perfil';

  @override
  String get navSettings => 'Ajustes';

  @override
  String navSignedInAs(String identity) {
    return 'Sesión iniciada como $identity';
  }

  @override
  String get settingsAddDeviceCopy => 'Copiar enlace';

  @override
  String get settingsAddDeviceLinkCopied => 'Enlace copiado';

  @override
  String settingsAddDeviceQr(String link) {
    return 'Código QR de $link';
  }

  @override
  String get settingsAddDeviceScan =>
      'Escanéalo con otro dispositivo para abrir Presence allí. Será un dispositivo nuevo, con su propio ID.';

  @override
  String settingsAddDeviceScanAs(String email) {
    return 'Escanéalo con otro dispositivo para abrir Presence allí como $email. Será un dispositivo nuevo, con su propio ID.';
  }

  @override
  String get settingsAddDeviceShare => 'Compartir';

  @override
  String get settingsAddDeviceShareTitle => 'Abrir Presence';

  @override
  String get settingsAddDeviceTitle => 'Añadir un dispositivo';

  @override
  String get settingsAdvancedSection => 'Avanzado';

  @override
  String get settingsAskNote => 'Con menos certeza, te pregunta si son ellos.';

  @override
  String get settingsAutoTag => 'Etiquetar automáticamente con al menos';

  @override
  String settingsAutoTagValue(int percent) {
    return '$percent % de certeza';
  }

  @override
  String get settingsBlinkSection => 'Cámaras Blink';

  @override
  String get settingsBrightness => 'Brillo';

  @override
  String get settingsCameraSection => 'Cámara';

  @override
  String get settingsClipAfter => 'Después de pulsar';

  @override
  String get settingsClipBefore => 'Antes de pulsar';

  @override
  String settingsClipsNote(int seconds) {
    return 'Los clips duran $seconds s en total. Cambiar \"Antes\" tarda hasta ese tiempo en aplicarse, mientras las cámaras acumulan historial.';
  }

  @override
  String get settingsClipsSection => 'Clips';

  @override
  String get settingsCloudFailed =>
      'No se pudo entrenar ahora; se reintentará más tarde.';

  @override
  String settingsCloudLastTrained(String time) {
    return 'Último entrenamiento $time';
  }

  @override
  String get settingsCloudNoLabels =>
      'Nada que aprender aún: etiqueta personas y mascotas.';

  @override
  String get settingsCloudNotPremium =>
      'El reconocimiento en la nube es solo Premium.';

  @override
  String get settingsCloudNotTrained => 'Aún sin entrenar';

  @override
  String settingsCloudStatus(String when) {
    return '$when. Aprende de las personas y mascotas que etiquetas; se revisa a diario.';
  }

  @override
  String get settingsCloudTitle => 'Reconocimiento en la nube (Premium)';

  @override
  String get settingsCloudTrain => 'Entrenar ahora';

  @override
  String get settingsCloudTrained => 'Entrenado.';

  @override
  String get settingsCloudUpToDate => 'Al día.';

  @override
  String get settingsCoordinatesAxes =>
      'Indica una latitud (N o S) y una longitud (E u O)';

  @override
  String get settingsCoordinatesEmpty => 'Pega una latitud y longitud';

  @override
  String get settingsCoordinatesInvalid =>
      'No es una posición: usa latitud, longitud, p. ej. 38.7223, -9.1393';

  @override
  String get settingsCoordinatesLatitudeRange =>
      'La latitud debe estar entre -90 y 90';

  @override
  String get settingsCoordinatesLongitudeRange =>
      'La longitud debe estar entre -180 y 180';

  @override
  String get settingsCoordinatesMinutes =>
      'Los minutos y segundos llegan hasta 59';

  @override
  String get settingsDeleteDeviceCancel => 'Cancelar';

  @override
  String get settingsDeleteDeviceChoice =>
      'Conservar videos: sale de la lista, sus eventos y videos se quedan. Borrar videos: sus eventos y videos también se ocultan en todos los dispositivos. En ambos casos, vuelve a aparecer si graba de nuevo.';

  @override
  String get settingsDeleteDeviceConfirm => 'Borrar videos';

  @override
  String settingsDeleteDeviceDone(String deviceId, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count eventos ocultos',
      one: '1 evento oculto',
    );
    return '$deviceId borrado: $_temp0';
  }

  @override
  String settingsDeleteDeviceFailed(String deviceId) {
    return 'No se pudo borrar $deviceId';
  }

  @override
  String get settingsDeleteDeviceKeep => 'Conservar videos';

  @override
  String settingsDeleteDeviceMessage(String deviceId, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Tiene $count eventos',
      one: 'Tiene 1 evento',
      zero: 'No tiene eventos aquí',
    );
    return '¿Quitar $deviceId de tus dispositivos? $_temp0.';
  }

  @override
  String settingsDeleteDeviceRemoved(String deviceId) {
    return '$deviceId quitado de la lista; sus videos se quedan';
  }

  @override
  String get settingsDeleteDeviceTitle => '¿Borrar dispositivo?';

  @override
  String get settingsDevice => 'Dispositivo';

  @override
  String get settingsDeviceLoading => 'cargando…';

  @override
  String get settingsGoProSection => 'Cámaras GoPro';

  @override
  String get settingsHistoryNote =>
      'Los eventos más antiguos y sus clips se borran de este dispositivo al iniciar la app y cada 3 horas.';

  @override
  String get settingsHistorySection => 'Historial';

  @override
  String get settingsJoinDismiss => 'Descartar';

  @override
  String settingsJoinOtherUser(String email) {
    return 'El enlace lo compartió otra cuenta de Google, no $email. Cierra sesión e inicia con esa para añadir este dispositivo.';
  }

  @override
  String get settingsJoinOtherUserUnknown =>
      'El enlace lo compartió otra cuenta de Google, no la tuya. Cierra sesión e inicia con esa para añadir este dispositivo.';

  @override
  String get settingsJoinSameDevice =>
      'Este es el dispositivo que compartió el enlace. Ábrelo en otro dispositivo para añadirlo.';

  @override
  String get settingsJoinSignIn =>
      'Para añadir este dispositivo, inicia sesión con la cuenta de Google que compartió el enlace.';

  @override
  String get settingsJoinSignOut => 'Cerrar sesión';

  @override
  String get settingsKeep => 'Conservar eventos durante';

  @override
  String settingsKeepDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count días',
      one: '1 día',
    );
    return '$_temp0';
  }

  @override
  String settingsKeepWeeks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count semanas',
      one: '1 semana',
    );
    return '$_temp0';
  }

  @override
  String get settingsLiveAdminNote =>
      'Siempre conectado para administradores, así este dispositivo siempre está accesible: los eventos de otros dispositivos llegan en un segundo.';

  @override
  String get settingsLiveAlways => 'Siempre';

  @override
  String get settingsLiveAlwaysNote =>
      'Se mantiene conectado: los eventos de otros dispositivos llegan en un segundo.';

  @override
  String get settingsLiveConnect => 'Conectar a la sincronización en vivo';

  @override
  String settingsLiveEvery(String interval) {
    return 'Cada $interval';
  }

  @override
  String settingsLiveFreeNote(String interval) {
    return 'Gratis: se conecta cada $interval para compartir los eventos de este dispositivo con tus otros dispositivos y recibir los suyos. Premium los sincroniza al instante.';
  }

  @override
  String get settingsLiveNever => 'Nunca';

  @override
  String get settingsLiveNeverNote =>
      'Los eventos de otros dispositivos llegan con cada sincronización (15 s), y los de este les llegan igual.';

  @override
  String settingsLiveScheduledNote(String interval) {
    return 'Se conecta cada $interval aprox. para recibir lo que enviaron otros dispositivos, y al instante para enviar los eventos de este.';
  }

  @override
  String get settingsLiveSection => 'Sincronización en vivo';

  @override
  String get settingsLocationDenied => 'Se denegó el permiso de ubicación';

  @override
  String get settingsLocationFinding => 'Buscando este dispositivo…';

  @override
  String settingsLocationMoveMap(String reason) {
    return '$reason. Mueve el mapa para fijarla.';
  }

  @override
  String get settingsLocationMyLocation => 'Mi ubicación';

  @override
  String get settingsLocationOff => 'La ubicación está desactivada';

  @override
  String get settingsLocationPaste => 'Pegar posición';

  @override
  String get settingsLocationPin => 'Fijar posición';

  @override
  String get settingsLocationPinThis => 'Fijar esta posición';

  @override
  String get settingsLocationPinnedLabel => 'Fijada:';

  @override
  String get settingsLocationPinnedStatus => 'Fijada · se usa en cada evento';

  @override
  String get settingsLocationPositionLabel => 'Posición (latitud, longitud)';

  @override
  String get settingsLocationSection => 'Ubicación';

  @override
  String get settingsLocationSetOnMap => 'Fijada en el mapa';

  @override
  String get settingsLocationSetThis => 'Usar esta posición';

  @override
  String get settingsLocationThisDevice => 'Ubicación de este dispositivo';

  @override
  String get settingsLocationUnavailable => 'Ubicación no disponible';

  @override
  String get settingsLocationUnknown => 'Ubicación desconocida';

  @override
  String get settingsLocationUnpin => 'Desfijar';

  @override
  String get settingsLocationUnpinToLocate => 'Desfija para usar mi ubicación';

  @override
  String get settingsMapAttribution => '© Colaboradores de OpenStreetMap';

  @override
  String get settingsMapZoomIn => 'Acercar';

  @override
  String get settingsMapZoomOut => 'Alejar';

  @override
  String settingsMemoryAbout(String amount) {
    return 'unos $amount';
  }

  @override
  String settingsMemoryFree(String amount) {
    return '$amount libres';
  }

  @override
  String get settingsMotionCooldown => 'Como máximo un clip automático cada';

  @override
  String settingsMotionNow(int percent) {
    return 'Movimiento ahora: $percent %';
  }

  @override
  String get settingsMotionNowWaiting =>
      'Movimiento ahora: esperando la cámara…';

  @override
  String get settingsMotionSection => 'Movimiento';

  @override
  String get settingsMotionSwitch => 'Grabar clip al detectar movimiento';

  @override
  String get settingsMotionThreshold => 'Umbral de movimiento';

  @override
  String settingsMotionThresholdValue(int percent) {
    return '$percent % de la imagen';
  }

  @override
  String get settingsNextClipDue =>
      'Próximo clip: pendiente, cuando se abra una cámara';

  @override
  String settingsNextClipIn(String time) {
    return 'Próximo clip en $time';
  }

  @override
  String get settingsNightMode => 'Modo noche';

  @override
  String get settingsNightModeSubtitle =>
      'Cuando está oscuro: la imagen más brillante, y una luz mientras graba un clip (la linterna, o la pantalla hacia la escena)';

  @override
  String get settingsObjectsSubtitle =>
      'Persona, gato, perro, bicicleta, botella… para buscar';

  @override
  String get settingsObjectsSwitch => 'Etiquetar objetos en clips nuevos';

  @override
  String get settingsProfile => 'Perfil';

  @override
  String get settingsProfileNone => 'ninguno hasta iniciar sesión';

  @override
  String get settingsRecognitionSection => 'Reconocimiento';

  @override
  String get settingsRecognitionSubtitle =>
      'Personas y mascotas ya etiquetadas, en este dispositivo';

  @override
  String get settingsRecognitionSwitch => 'Reconocer sujetos en clips nuevos';

  @override
  String get settingsRecognitionUnavailable =>
      'Aún no disponible en este dispositivo';

  @override
  String get settingsSameAsClip => 'Igual que pulsar Clip';

  @override
  String get settingsScheduleEvery => 'Un clip cada';

  @override
  String get settingsScheduleSection => 'Clips programados';

  @override
  String get settingsScheduleSwitch =>
      'Grabar clip al iniciar y periódicamente';

  @override
  String get settingsShowLog => 'Mostrar la pestaña Registro';

  @override
  String get settingsShowLogSubtitle =>
      'Los últimos mensajes y el estado de la app';

  @override
  String get settingsStartupClip =>
      'Clip de inicio: cuando la cámara esté lista';

  @override
  String get settingsSubjectEvents => 'Cuántos eventos cargar a la vez';

  @override
  String get settingsSubjectsSection => 'Sujetos';

  @override
  String storeDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count días',
      one: '1 día',
    );
    return '$_temp0';
  }

  @override
  String storeDeleteAccountSubscription(String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'App Store',
      'google': 'Google Play',
      'other': 'la tienda',
    });
    return 'Eliminar tu cuenta no cancela una suscripción Premium: cancélala antes en los ajustes de suscripciones de $_temp0.';
  }

  @override
  String get storeEveryDay => 'día';

  @override
  String storeEveryDays(int count) {
    return '$count días';
  }

  @override
  String get storeEveryMonth => 'mes';

  @override
  String storeEveryMonths(int count) {
    return '$count meses';
  }

  @override
  String get storeEveryWeek => 'semana';

  @override
  String storeEveryWeeks(int count) {
    return '$count semanas';
  }

  @override
  String get storeEveryYear => 'año';

  @override
  String storeEveryYears(int count) {
    return '$count años';
  }

  @override
  String get storeFailed =>
      'Aún no se pudo confirmar la compra con Presence. Se vuelve a intentar automáticamente.';

  @override
  String get storeLoading => 'Cargando los planes…';

  @override
  String get storeManage => 'Gestionar suscripción';

  @override
  String storeMonths(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count meses',
      one: '1 mes',
    );
    return '$_temp0';
  }

  @override
  String get storeNotVerified => 'La tienda no confirmó esta compra.';

  @override
  String get storeNothingToRestore =>
      'No hay ninguna suscripción activa para restaurar.';

  @override
  String get storeOtherAccount =>
      'Esta suscripción pertenece a otra cuenta de Presence.';

  @override
  String get storePending =>
      'Compra pendiente: Premium empieza cuando la tienda la confirme.';

  @override
  String storePlanFreeText(int free, int premium) {
    return 'Gratis: cada dispositivo guarda sus eventos, y hasta $free dispositivos los comparten cada 15 minutos. Premium los sincroniza al instante, con copia en la nube y hasta $premium dispositivos.';
  }

  @override
  String get storePlanMonthly => 'Premium mensual';

  @override
  String storePlanPrice(String plan, String price, String period) {
    return '$plan: $price / $period';
  }

  @override
  String get storePlanYearly => 'Premium anual';

  @override
  String get storePrivacy => 'Política de privacidad';

  @override
  String get storePurchaseFailed => 'La compra no se completó.';

  @override
  String get storePurchased => '¡Gracias! Premium está activo.';

  @override
  String storeRenews(String store) {
    String _temp0 = intl.Intl.selectLogic(store, {
      'apple': 'App Store',
      'google': 'Google Play',
      'other': 'la tienda',
    });
    return 'Las suscripciones se renuevan automáticamente hasta que las canceles en los ajustes de tu cuenta de $_temp0, al menos 24 horas antes de que termine el periodo.';
  }

  @override
  String get storeRestore => 'Restaurar compras';

  @override
  String get storeRestored => 'Tu suscripción se ha restaurado.';

  @override
  String get storeTerms => 'Términos del servicio';

  @override
  String storeTrial(String trial, String price, String period) {
    return '$trial gratis, luego $price / $period.';
  }

  @override
  String get storeUnavailable => 'Las compras no están disponibles ahora.';

  @override
  String storeWeeks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count semanas',
      one: '1 semana',
    );
    return '$_temp0';
  }

  @override
  String storeYears(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count años',
      one: '1 año',
    );
    return '$_temp0';
  }

  @override
  String subjectsEvents(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count eventos',
      one: '$count evento',
    );
    return '$_temp0';
  }

  @override
  String subjectsLatestEvents(int shown, int total) {
    return 'Últimos $shown de $total eventos';
  }

  @override
  String get subjectsNoLocation => 'Sin ubicación';

  @override
  String get subjectsNobodyTagged =>
      'Ya no hay nadie etiquetado con este nombre.';

  @override
  String subjectsOpen(String name) {
    return 'Abrir $name';
  }

  @override
  String subjectsOpenEvent(String label) {
    return 'Abrir evento $label';
  }

  @override
  String get subjectsRecognizedAuto => 'Reconocido automáticamente';
}
