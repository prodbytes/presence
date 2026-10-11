// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get aboutLinkCopied => 'Link copiado';

  @override
  String get aboutOpenSource => 'O Presence é de código aberto:';

  @override
  String get aboutParagraph =>
      'O Presence transforma um celular, tablet, notebook ou Raspberry Pi em uma câmera sempre ligada para um lugar de que você cuida: imagens ao vivo, clipes que incluem os momentos anteriores e clipes ao detectar movimento. Só grave onde for permitido.';

  @override
  String get authAccessAdmin => 'Acesso admin';

  @override
  String get authAccessFree => 'Acesso grátis';

  @override
  String get authAccessPremium => 'Acesso Premium';

  @override
  String get authBackedUp => 'Os clipes e eventos estão com backup';

  @override
  String authBackedUpBoth(int up, int down) {
    return 'Backup feito ($up enviados, $down restaurados)';
  }

  @override
  String authBackedUpRestored(int down) {
    return 'Backup feito ($down restaurados)';
  }

  @override
  String authBackedUpUploaded(int up) {
    return 'Backup feito ($up enviados)';
  }

  @override
  String get authBackupOff => 'O backup na nuvem está desativado';

  @override
  String get authCheckAgain => 'Verificar de novo';

  @override
  String get authCheckingRoles => 'Verificando funções…';

  @override
  String authDeleteDevice(String device) {
    return 'Excluir $device';
  }

  @override
  String authDeviceCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dispositivos',
      one: '1 dispositivo',
      zero: '0 dispositivos',
    );
    return '$_temp0';
  }

  @override
  String authDevicesHidden(int count, String plan, int limit) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Os eventos de $count dispositivos estão ocultos: $plan mostra seus primeiros $limit dispositivos.',
      one:
          'Os eventos de 1 dispositivo estão ocultos: $plan mostra seus primeiros $limit dispositivos.',
    );
    return '$_temp0';
  }

  @override
  String get authFeedback => 'Feedback';

  @override
  String get authFeedbackIntro =>
      'Mensagens dos membros na aba Ajuda, as mais recentes primeiro. Suas respostas aparecem lá.';

  @override
  String authFeedbackLoadFailed(String error) {
    return 'Não foi possível carregar o feedback ($error).';
  }

  @override
  String get authHaveCode =>
      'Tem um código da sua outra conta? Digite-o para vincular esta a ela.';

  @override
  String get authHidden => 'oculto';

  @override
  String get authHiddenTooltip =>
      'Passou do limite de dispositivos do plano: sincroniza, mas os eventos dele ficam ocultos aqui';

  @override
  String get authLinkAnother => 'Vincular outra conta';

  @override
  String get authLinkCode => 'Código de vínculo';

  @override
  String get authLinkCodeHelp =>
      'Em até 10 minutos, entre com a outra conta do Google e digite este código em Contas vinculadas.';

  @override
  String get authLinkCodeWrong =>
      'Esse código está errado, já foi usado ou expirou.';

  @override
  String get authLinkConflict =>
      'Esta conta não pode ser vinculada: ela tem dados próprios na nuvem ou outras contas vinculadas a ela.';

  @override
  String get authLinkNoBackup =>
      'O backup na nuvem não está configurado, então não dá para vincular contas.';

  @override
  String get authLinkOtherAccount =>
      'Tem acesso com outra conta do Google? Vincule-a';

  @override
  String get authLinkThis => 'Vincular esta conta';

  @override
  String get authLinkTooMany =>
      'Tentativas demais. Espere um minuto e tente de novo.';

  @override
  String get authLinkedAccounts => 'Contas vinculadas';

  @override
  String get authLinkedIntro =>
      'Qualquer uma destas contas do Google acessa os mesmos clipes e eventos.';

  @override
  String authLinkedTo(String owner) {
    return 'Vinculada a $owner.';
  }

  @override
  String get authLinkedToProfile => 'Vinculada ao perfil.';

  @override
  String authMoreHidden(int count, String plan, int limit) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Mais $count dispositivos sincronizam, mas os eventos deles ficam ocultos: $plan mostra seus primeiros $limit.',
      one:
          'Mais 1 dispositivo sincroniza, mas os eventos dele ficam ocultos: $plan mostra seus primeiros $limit.',
    );
    return '$_temp0';
  }

  @override
  String get authNoEvents => 'Sem eventos';

  @override
  String get authNoFeedback => 'Ainda não há feedback.';

  @override
  String get authNoRoles => 'Ainda sem funções';

  @override
  String get authNotSignedIn => 'Você não entrou.';

  @override
  String authOpenHost(String host) {
    return 'Abrir $host';
  }

  @override
  String get authOsUnknown => 'Sistema operacional desconhecido';

  @override
  String authOthersHidden(String plan, int limit) {
    return 'Os eventos dos seus outros dispositivos ficam ocultos neste: $plan mostra seus primeiros $limit dispositivos.';
  }

  @override
  String get authOwner => 'Proprietária';

  @override
  String authPastLimit(int limit) {
    return 'Este dispositivo passou dos seus primeiros $limit: sincroniza, mas os eventos dele ficam ocultos nos outros dispositivos, e os deles aqui.';
  }

  @override
  String get authPlanFree => 'Grátis';

  @override
  String authPlanFreeText(int free, int premium) {
    return 'Grátis: até $free dispositivos sincronizam entre si quando online. O Premium adiciona backup na nuvem e até $premium dispositivos: US\$20 por mês, a primeira semana grátis.';
  }

  @override
  String get authPlanPremium => 'Premium';

  @override
  String authPlanPremiumText(int limit) {
    return 'Premium: backup na nuvem e até $limit dispositivos sincronizados.';
  }

  @override
  String authPremiumShowsUpTo(String text, int limit) {
    return '$text O Premium mostra até $limit.';
  }

  @override
  String get authProfile => 'Perfil';

  @override
  String get authRbacrText =>
      'Os códigos de cupom e o modo de manutenção são gerenciados no rbacr, que guarda todas as funções. Os membros resgatam códigos na tela Assinar.';

  @override
  String get authRedeem => 'Resgatar';

  @override
  String get authReload => 'Recarregar';

  @override
  String authReplyFailed(String email, String error) {
    return 'Não foi possível responder a $email ($error)';
  }

  @override
  String authRequestFailed(int status) {
    return 'A solicitação falhou (HTTP $status).';
  }

  @override
  String get authRetry => 'Tentar de novo';

  @override
  String get authRoleRoot => 'Root';

  @override
  String authRolesSemantics(String roles) {
    return 'Funções: $roles';
  }

  @override
  String get authSignIn => 'Entrar';

  @override
  String get authSignInToPresence => 'Entre no Presence';

  @override
  String get authSignInWithGoogle => 'Entrar com o Google';

  @override
  String get authSignOut => 'Sair';

  @override
  String get authSignUp => 'Assinar';

  @override
  String authSignedInAs(String identity) {
    return 'Conectado como $identity';
  }

  @override
  String authSomethingWrong(String error) {
    return 'Algo deu errado ($error).';
  }

  @override
  String get authSubscribe => 'Assinar';

  @override
  String get authSubscribeButton => 'Assinar em nu01.com';

  @override
  String authSubscribeText(String email) {
    return '$email ainda não tem acesso ao Presence. Assine em nu01.com: grátis, ou Premium para backup na nuvem e mais dispositivos. Depois verifique de novo aqui.';
  }

  @override
  String get authSyncFree =>
      'Seus dispositivos sincronizam entre si quando estão online';

  @override
  String get authThisAccount => 'Esta conta';

  @override
  String get authThisDevice => 'este dispositivo';

  @override
  String get authUnavailable => 'Não é possível entrar.';

  @override
  String get authUnlink => 'Desvincular';

  @override
  String authUnlinked(String email) {
    return '$email foi desvinculada.';
  }

  @override
  String get authUpgrade => 'Assinar';

  @override
  String get authUpgradePremium => 'Assinar o Premium';

  @override
  String get authUploadFailed => 'Falha no envio';

  @override
  String get authUploading => 'Enviando…';

  @override
  String authVoucherDiscount(int discount) {
    return 'Esse código dá $discount% de desconto. Ainda não dá para pagar o resto, então ele não libera o acesso.';
  }

  @override
  String get authVoucherFailed => 'Não foi possível resgatar o código.';

  @override
  String authVoucherFailedDetail(String error) {
    return 'Não foi possível resgatar o código ($error).';
  }

  @override
  String get authVoucherInvalid =>
      'Esse código é inválido, expirou ou já foi usado.';

  @override
  String get authVoucherLabel => 'Código de cupom';

  @override
  String get authVoucherPayment =>
      'Esse código exige um pagamento, que ainda não está disponível, então ele não libera o acesso.';

  @override
  String get authVoucherPrompt =>
      'Tem um código de cupom? Resgate para entrar na hora.';

  @override
  String get authVoucherTooMany =>
      'Tentativas demais. Espere um pouco e tente de novo.';

  @override
  String get authVouchersTitle => 'Cupons e manutenção';

  @override
  String get authYourAccount => 'Sua conta';

  @override
  String get cameraActionAll => 'Mostrar todos os dispositivos';

  @override
  String get cameraActionNormal => 'Voltar ao normal: esta câmera';

  @override
  String get cameraActionStopped => 'Parar: sem capturar nem sincronizar';

  @override
  String get cameraActionUnattended =>
      'Modo desatendido: tela apagada, ainda capturando';

  @override
  String cameraAgeDays(int days) {
    return 'há $days d';
  }

  @override
  String cameraAgeHours(int hours) {
    return 'há $hours h';
  }

  @override
  String get cameraAgeJustNow => 'agora mesmo';

  @override
  String cameraAgeMinutes(int minutes) {
    return 'há $minutes min';
  }

  @override
  String cameraAgeSeconds(int seconds) {
    return 'há $seconds s';
  }

  @override
  String get cameraAskedFreshGrab => 'Pedida uma imagem nova';

  @override
  String get cameraClip => 'Clipe';

  @override
  String get cameraClipCameraOff => 'Câmera desligada';

  @override
  String cameraClipCountdown(String time) {
    return 'Clipe · $time';
  }

  @override
  String get cameraClipLoadFailed => 'Não foi possível carregar este clipe';

  @override
  String cameraClipNextIn(String countdown) {
    return 'Próximo clipe automático em $countdown';
  }

  @override
  String get cameraClipNoCamera => 'Sem câmera';

  @override
  String get cameraClipNotReady => 'Câmera não está pronta';

  @override
  String get cameraClipPreview => 'Prévia';

  @override
  String get cameraClipReady => 'Pronto';

  @override
  String cameraClipRecordingNext(int seconds) {
    return 'Gravando os próximos $seconds s…';
  }

  @override
  String get cameraClipSaving => 'Salvando clipe…';

  @override
  String cameraClipSavingNext(String next) {
    return 'Salvando clipe… $next';
  }

  @override
  String get cameraClipStarting => 'Iniciando a câmera…';

  @override
  String get cameraClipUnavailable => 'Câmera indisponível';

  @override
  String cameraCouldNotOpen(String reason) {
    return 'Não foi possível abrir a câmera\n$reason';
  }

  @override
  String get cameraErrorBlocked =>
      'O acesso à câmera está bloqueado para este site. Permita a câmera nas configurações do site no navegador e tente de novo.';

  @override
  String get cameraErrorDenied =>
      'A permissão da câmera foi negada. Permita em Ajustes.';

  @override
  String get cameraErrorGeneric => 'Algo deu errado ao iniciar a câmera.';

  @override
  String get cameraErrorInUse =>
      'Outro app está usando a câmera, ou ela não pôde iniciar. Feche os apps que a usam e tente de novo.';

  @override
  String get cameraErrorInsecure =>
      'A câmera só funciona em uma página segura. Abra o Presence por HTTPS.';

  @override
  String get cameraErrorNoneFound =>
      'Nenhuma câmera foi encontrada. Conecte uma e tente de novo.';

  @override
  String get cameraErrorStopped => 'A câmera parou (desconectada ou removida)';

  @override
  String get cameraFlip => 'Trocar câmera';

  @override
  String cameraLiveLabel(String device) {
    return '$device · ao vivo';
  }

  @override
  String get cameraModeAll => 'Todas';

  @override
  String get cameraModeNormal => 'Normal';

  @override
  String get cameraModeStopped => 'Parado';

  @override
  String get cameraModeUnattended => 'Desatendido';

  @override
  String get cameraNotFound => 'Nenhuma câmera encontrada';

  @override
  String get cameraOffMessage =>
      'Câmera desligada\nNada é gravado até você ligá-la.';

  @override
  String get cameraRetry => 'Tentar de novo';

  @override
  String get cameraThisDevice => 'Este dispositivo';

  @override
  String get cameraTurnOn => 'Ligar';

  @override
  String get clipAuto => 'Auto';

  @override
  String get clipAutoAllTagged =>
      'Todos os sujeitos já nomeados estão neste clipe.';

  @override
  String get clipAutoDeferred =>
      'O celular está com pouca memória: tente de novo daqui a pouco.';

  @override
  String get clipAutoFailed =>
      'Não foi possível executar o reconhecimento; tente de novo.';

  @override
  String clipAutoFound(String names) {
    return 'Encontrado: $names.';
  }

  @override
  String get clipAutoLooking => 'Buscando os sujeitos já nomeados…';

  @override
  String get clipAutoNoReferences =>
      'Ainda não há sujeitos para buscar: primeiro nomeie alguém em outro clipe.';

  @override
  String get clipAutoNone => 'Nenhum sujeito reconhecido.';

  @override
  String clipAutoNotSureMany(String names) {
    return 'Sem certeza sobre $names: responda as perguntas nos eventos.';
  }

  @override
  String clipAutoNotSureOne(String names, String name) {
    return 'Sem certeza sobre $names: responda \"É $name?\" nos eventos.';
  }

  @override
  String clipAutoTags(String subjects, String tags) {
    return '$subjects Tags: $tags.';
  }

  @override
  String get clipAutoTooltip =>
      'Busca os sujeitos já nomeados e marca o que aparece, neste dispositivo';

  @override
  String get clipAutoUnavailable => 'Ainda não disponível neste dispositivo';

  @override
  String get clipAutoUnsupported =>
      'O reconhecimento ainda não está disponível neste dispositivo.';

  @override
  String get clipAutoWaiting => 'Aguardando o clipe terminar de gravar…';

  @override
  String get clipCancel => 'Cancelar';

  @override
  String get clipClose => 'Fechar';

  @override
  String get clipDone => 'Concluído';

  @override
  String get clipFrameTagLabel =>
      'Quadro para nomear sujeitos: clique em uma pessoa ou pet para nomeá-lo';

  @override
  String get clipGrabFailed =>
      'Não foi possível capturar este quadro; tente de novo';

  @override
  String clipIdentifyHint(String label) {
    return '$label: clique no vídeo para nomeá-lo, ou tente Auto.';
  }

  @override
  String get clipNameHint => 'Nome';

  @override
  String get clipNameMore => 'Nomear mais sujeitos neste quadro';

  @override
  String get clipNameSubject => 'Nomear sujeito';

  @override
  String clipNamesAnd(String first, String last) {
    return '$first e $last';
  }

  @override
  String get clipNoSubjects =>
      'Nenhum sujeito ainda. Clique em uma pessoa ou pet no vídeo para nomeá-lo.';

  @override
  String get clipNoTags => 'Sem tags: nada foi visto neste clipe.';

  @override
  String get clipNoTagsYet =>
      'Nenhuma tag ainda. O que aparece no clipe, como garrafa ou bicicleta, aparece aqui depois da análise.';

  @override
  String get clipNoTagsYetTryAuto =>
      'Nenhuma tag ainda. O que aparece no clipe, como garrafa ou bicicleta, aparece aqui depois da análise (tente Auto).';

  @override
  String get clipNoVideo => 'Nenhum vídeo gravado';

  @override
  String get clipNotRecordedClosed =>
      'Não gravado: o app fechou durante a gravação';

  @override
  String clipNotSaved(String status, String error) {
    return '$status · não salvo: $error';
  }

  @override
  String get clipPlay => 'Reproduzir o clipe';

  @override
  String clipPreviousOnly(int before, int after) {
    return 'Só os $before s anteriores: o app fechou antes de gravar os $after s seguintes';
  }

  @override
  String clipPreviousReady(int before, int after) {
    return '$before s anteriores prontos · gravando $after s seguintes…';
  }

  @override
  String clipReady(int seconds) {
    return 'Clipe de $seconds s pronto';
  }

  @override
  String get clipRecordingElsewhere => 'Gravando em outro dispositivo…';

  @override
  String get clipRecordingFailed => 'A gravação falhou';

  @override
  String clipRecordingNext(int after) {
    return 'Gravando $after s seguintes…';
  }

  @override
  String get clipRemoveSubject => 'Remover sujeito';

  @override
  String clipRemoveSubjectFromEvent(String label) {
    return 'Remover o sujeito $label deste evento';
  }

  @override
  String clipRemoveTagFromEvent(String label) {
    return 'Remover a tag $label deste evento';
  }

  @override
  String get clipRenameSubject => 'Renomear sujeito';

  @override
  String get clipSave => 'Salvar';

  @override
  String clipSavingPrevious(int before) {
    return 'Salvando $before s anteriores…';
  }

  @override
  String clipShowAt(String time) {
    return 'Ver em $time';
  }

  @override
  String get clipShowEveryEvent => 'Ver todos os eventos';

  @override
  String get clipShowEveryHold => 'Ver todos os eventos (segure para renomear)';

  @override
  String clipShowOnlyHold(String name) {
    return 'Ver só eventos com $name (segure para renomear)';
  }

  @override
  String clipShowOnlyWith(String label) {
    return 'Ver só eventos com $label';
  }

  @override
  String get clipSubjects => 'Sujeitos';

  @override
  String clipTagHint(String time) {
    return 'Clique em cada pessoa ou pet no vídeo para nomeá-lo como sujeito (quadro em $time).';
  }

  @override
  String get clipTags => 'Tags';

  @override
  String get clipUnsupported =>
      'Clipes de vídeo não são compatíveis com esta plataforma';

  @override
  String get clipWhoIsThis => 'Quem é?';

  @override
  String get connectivityAllGood => 'Online · sincronização ao vivo conectada';

  @override
  String get connectivityChecking => 'Verificando a conexão…';

  @override
  String get connectivityCloudFailed => 'Falha na sincronização na nuvem';

  @override
  String get connectivityCloudNotSet =>
      'A sincronização na nuvem não está configurada nesta versão';

  @override
  String get connectivityCloudOn => 'Sincronização na nuvem ativa';

  @override
  String get connectivityCloudOneSide =>
      'A sincronização na nuvem está configurada só de um lado';

  @override
  String get connectivityFree => 'Free: os dispositivos sincronizam ao vivo';

  @override
  String connectivityLabel(String headline) {
    return 'Conectividade: $headline';
  }

  @override
  String get connectivityLiveConnected => 'Sincronização ao vivo conectada';

  @override
  String get connectivityLiveConnecting =>
      'Conectando a sincronização ao vivo…';

  @override
  String get connectivityLiveFailed => 'Falha na sincronização ao vivo';

  @override
  String connectivityLiveIdle(String next) {
    return 'Sincronização ao vivo em espera · próxima em $next';
  }

  @override
  String get connectivityLiveNotSet =>
      'A sincronização ao vivo não está configurada nesta versão';

  @override
  String get connectivityLiveOff => 'A sincronização ao vivo está desativada';

  @override
  String get connectivityLiveOnceSynced =>
      'A sincronização ao vivo conecta após sincronizar';

  @override
  String get connectivityNote =>
      'Os outros dispositivos veem este ao vivo só enquanto a sincronização ao vivo está conectada.';

  @override
  String get connectivityOffline =>
      'Offline: não foi possível acessar o servidor';

  @override
  String get connectivityOnline => 'Online';

  @override
  String connectivityPresenceAnswered(String since) {
    return 'Ao vivo — respondeu $since';
  }

  @override
  String connectivityPresenceLastSeen(String since, String unavailable) {
    return 'Visto pela última vez $since$unavailable';
  }

  @override
  String connectivityPresenceNever(String unavailable) {
    return 'Nunca visto$unavailable';
  }

  @override
  String get connectivityPresenceThisLive =>
      'Ao vivo — este dispositivo, conectado à sincronização ao vivo';

  @override
  String get connectivityPresenceThisNotConnected =>
      'Este dispositivo — sem conexão à sincronização ao vivo agora';

  @override
  String get connectivityPresenceThisUnavailable =>
      'Este dispositivo — status ao vivo indisponível';

  @override
  String get connectivityPresenceUnavailable =>
      ' · status ao vivo indisponível';

  @override
  String connectivityThisDevice(String headline) {
    return 'Este dispositivo — $headline';
  }

  @override
  String get consentAgree => 'Concordo';

  @override
  String get consentBiometricsDetail =>
      'Pelo GDPR, rostos usados para identificar pessoas, como ao nomeá-las em clipes, exigem cuidado: consentimento claro, guarda segura e exclusão quando solicitada.';

  @override
  String get consentBiometricsTitle =>
      'Rostos são dados biométricos, e eu sou responsável.';

  @override
  String get consentFootnote =>
      'Perguntado uma vez neste dispositivo. Não é aconselhamento jurídico.';

  @override
  String get consentIntro => 'Ao continuar, você confirma:';

  @override
  String get consentRightDetail =>
      'Sou dono ou administro este local, ou tenho permissão, e as pessoas que podem ser filmadas sabem disso.';

  @override
  String get consentRightTitle => 'Tenho o direito de gravar aqui.';

  @override
  String get consentTitle => 'Antes de o Presence começar a gravar';

  @override
  String get devModeTooltip =>
      'Modo de desenvolvimento: o login não está configurado, então tudo fica aberto a todos.';

  @override
  String devModeTooltipVersion(String version) {
    return 'Modo de desenvolvimento, versão $version: o login não está configurado, então tudo fica aberto a todos.';
  }

  @override
  String get eventAlreadyDeleted => 'O evento já foi excluído';

  @override
  String get eventCancel => 'Cancelar';

  @override
  String eventCopies(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cópias',
      one: '$count cópia',
    );
    return '$_temp0';
  }

  @override
  String get eventCopiesCloud => 'Nuvem';

  @override
  String get eventCopiesLiveOff =>
      'A sincronização ao vivo está desativada: as cópias de outros dispositivos são desconhecidas';

  @override
  String get eventCopiesNone => 'Nenhuma cópia conhecida';

  @override
  String get eventCopiesNotSynced => 'Não sincronizado';

  @override
  String get eventCopiesThisDevice => 'Este dispositivo';

  @override
  String get eventDelete => 'Excluir evento';

  @override
  String get eventDeleteClipNote => 'O clipe fica na nuvem até expirar.';

  @override
  String get eventDeleteConfirm => 'Excluir';

  @override
  String get eventDeleteFailed => 'Não foi possível excluir o evento';

  @override
  String get eventDeleteMessage =>
      'Excluir este evento? Ele ficará oculto em todos os dispositivos.';

  @override
  String get eventDeleteTitle => 'Excluir evento?';

  @override
  String get eventDeletedEverywhere =>
      'Evento excluído em todos os dispositivos';

  @override
  String get eventDetailCaptureAll => 'Cada dispositivo grava um clipe';

  @override
  String get eventDetailClipMissing => 'Gravação do clipe ausente';

  @override
  String eventDetailSure(int percent) {
    return '$percent % de certeza';
  }

  @override
  String get eventDevice => 'Dispositivo';

  @override
  String get eventDeviceUnknown => 'Dispositivo desconhecido';

  @override
  String eventFlagIdentify(String label) {
    return '$label · Identificar';
  }

  @override
  String get eventFlagUnidentified => 'Sujeito não identificado';

  @override
  String get eventFlagUnidentifiedTooltip =>
      'Sujeito não identificado — identificar';

  @override
  String get eventLocationDevice => 'Posição do dispositivo';

  @override
  String get eventLocationMap => 'Marcada no mapa';

  @override
  String get eventLocationPinned => 'Fixada';

  @override
  String get eventNoLocation => 'Este evento não tem local';

  @override
  String get eventOsUnknown => 'Sistema operacional desconhecido';

  @override
  String get eventSuggestionClipMissing => 'O clipe está ausente';

  @override
  String get eventSuggestionNo => 'Não';

  @override
  String eventSuggestionNot(String name) {
    return 'Não é $name';
  }

  @override
  String eventSuggestionTagged(String name) {
    return 'Marcado como $name';
  }

  @override
  String eventSuggestionYes(String name) {
    return 'Sim, é $name';
  }

  @override
  String get eventThisDevice => 'este dispositivo';

  @override
  String get eventTitleAppStarted => 'Aplicativo iniciado';

  @override
  String get eventTitleCaptureAll => 'Capturar tudo';

  @override
  String get eventTitleClipRequested => 'Clipe solicitado';

  @override
  String get eventTitleConsentGiven => 'Consentimento de gravação dado';

  @override
  String get eventTitleGeneric => 'Evento';

  @override
  String eventTitleIsThis(String name) {
    return 'É $name?';
  }

  @override
  String get eventTitleMotion => 'Movimento detectado';

  @override
  String get eventTitleScheduled => 'Clipe agendado';

  @override
  String get eventTitleSignedIn => 'Sessão iniciada';

  @override
  String get eventTitleSignedOut => 'Sessão encerrada';

  @override
  String get eventTitleStartup => 'Clipe de início';

  @override
  String get eventWhere => 'Onde';

  @override
  String eventsCountTooltip(int shown, int all) {
    return '$shown de $all eventos exibidos';
  }

  @override
  String get eventsHideSystem => 'Ocultar eventos do sistema';

  @override
  String get eventsNoGrabs =>
      'Nenhuma captura ainda: os eventos do sistema estão ocultos';

  @override
  String eventsNoMatch(String query) {
    return 'Nenhum evento corresponde a \"$query\"';
  }

  @override
  String get eventsNone => 'Nenhum evento';

  @override
  String get eventsSearch => 'Buscar eventos';

  @override
  String get eventsSearchClear => 'Limpar busca';

  @override
  String get eventsShowDevice => 'Ver os eventos deste dispositivo';

  @override
  String get eventsShowEveryDevice => 'Ver os eventos de todos os dispositivos';

  @override
  String get eventsShowSystem => 'Mostrar eventos do sistema';

  @override
  String get feedbackAdmin => 'Admin';

  @override
  String get feedbackAnswered => 'Respondido';

  @override
  String get feedbackAwaitingReply => 'Aguardando resposta';

  @override
  String get feedbackMember => 'Membro';

  @override
  String get feedbackReply => 'Responder';

  @override
  String feedbackSendFailed(String error) {
    return 'Não foi possível enviar ($error).';
  }

  @override
  String get feedbackSentTooMuch => 'Você enviou muito hoje. Tente amanhã.';

  @override
  String get feedbackTeam => 'Equipe Presence';

  @override
  String get feedbackTooManyTries => 'Tentativas demais. Aguarde um minuto.';

  @override
  String get feedbackYou => 'Você';

  @override
  String healthApiAnswered(String mode) {
    return 'API de autenticação: respondeu (modo $mode)';
  }

  @override
  String get healthApiChecking => 'API de autenticação: verificando';

  @override
  String healthApiUnreachable(String error) {
    return 'API de autenticação: inacessível ($error)';
  }

  @override
  String get healthAuthApiName => 'API de autenticação';

  @override
  String get healthAwsOff => 'os eventos ficam neste dispositivo';

  @override
  String get healthAwsSet => 'AWS: configurado; sincroniza ao entrar';

  @override
  String healthAwsSyncFailed(String error) {
    return 'AWS: falha na sincronização ($error)';
  }

  @override
  String get healthAwsSynced => 'AWS: sincronizado';

  @override
  String get healthAwsSyncing => 'AWS: sincronizando';

  @override
  String get healthChecking => 'Verificando…';

  @override
  String healthChecks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count verificações',
      one: '1 verificação',
    );
    return '$_temp0';
  }

  @override
  String get healthDevicesHere => 'Nos eventos deste dispositivo';

  @override
  String get healthDevicesProfile => 'Nos eventos do perfil';

  @override
  String healthDevicesSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dispositivos nos eventos',
      one: '1 dispositivo nos eventos',
    );
    return '$_temp0';
  }

  @override
  String get healthDevicesTitle => 'Dispositivos';

  @override
  String healthDevicesTooltip(String what) {
    return '$what, aqui e sincronizados da nuvem';
  }

  @override
  String healthLastUpdate(String time) {
    return 'Última atualização $time';
  }

  @override
  String healthLiveConnected(String counts) {
    return 'Ao vivo: conectado ($counts)';
  }

  @override
  String get healthLiveConnecting => 'Ao vivo: conectando';

  @override
  String healthLiveCounts(int received, int sent) {
    return '$received recebidos, $sent enviados';
  }

  @override
  String healthLiveFailed(String error) {
    return 'Ao vivo: falhou ($error); os eventos chegam a cada sincronização';
  }

  @override
  String healthLiveIdle(String next, String mode, String counts) {
    return 'Ao vivo: em espera · próxima em $next ($mode; $counts)';
  }

  @override
  String get healthLiveName => 'Ao vivo';

  @override
  String get healthLiveNever =>
      'Ao vivo: desativado (Nunca); os eventos chegam a cada sincronização (15 s)';

  @override
  String get healthLiveNotSet =>
      'Ao vivo: não configurado; os eventos chegam a cada sincronização (15 s)';

  @override
  String get healthLiveOff => 'Ao vivo: configurado; conecta após sincronizar';

  @override
  String healthMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get healthOidcOff => 'o login está desativado';

  @override
  String get healthOidcSet => 'OIDC: login com Google configurado';

  @override
  String get healthRbacrDev => 'RBACR: não usado no modo DEV (ninguém entra)';

  @override
  String get healthRbacrFree =>
      'RBACR: configurado; este perfil é Free (seus dispositivos sincronizam entre si)';

  @override
  String get healthRbacrMissing =>
      'RBACR: não configurado na API de autenticação; ninguém que entrar terá um papel';

  @override
  String get healthRbacrPremium =>
      'RBACR: configurado; este perfil é Premium (backup na nuvem)';

  @override
  String get healthRbacrSet => 'RBACR: configurado; atribui os papéis';

  @override
  String get healthRbacrUnknown => 'RBACR: a API de autenticação não informa';

  @override
  String get healthRunFailed => 'falhou';

  @override
  String get healthRunPassed => 'tudo certo';

  @override
  String healthSeconds(int seconds) {
    return '$seconds s';
  }

  @override
  String healthSettingNotInBuild(String name, String off) {
    return '$name: não configurado nesta versão; $off';
  }

  @override
  String healthSettingNotSet(String name, String off) {
    return '$name: não configurado; $off';
  }

  @override
  String healthSettingOnlyApi(String name, String off) {
    return '$name: configurado na API de autenticação mas não nesta versão; $off';
  }

  @override
  String healthSettingOnlyBuild(String name) {
    return '$name: configurado nesta versão mas não na API de autenticação';
  }

  @override
  String get healthTapForDetails => 'Toque para ver detalhes.';

  @override
  String get healthTimeline => 'Linha do tempo';

  @override
  String healthTimelineSummary(String checks, String interval) {
    return '$checks · a cada $interval';
  }

  @override
  String get healthTitle => 'Saúde';

  @override
  String get healthToneChecking => 'Verificando';

  @override
  String get healthToneFailed => 'Falhou';

  @override
  String get healthToneIdle => 'Em espera';

  @override
  String get healthToneMismatch => 'Divergência';

  @override
  String get healthToneOff => 'Desligado';

  @override
  String get healthToneOk => 'OK';

  @override
  String get healthToneSyncing => 'Sincronizando';

  @override
  String get healthUnknownError => 'erro desconhecido';

  @override
  String get healthWarningFailed => 'Falha na verificação de saúde';

  @override
  String get helpIntro =>
      'Dúvidas, ideias ou algo não funciona? Envie uma mensagem; um administrador responderá aqui.';

  @override
  String helpLoadFailed(String error) {
    return 'Não foi possível carregar as mensagens ($error).';
  }

  @override
  String get helpMessage => 'Mensagem';

  @override
  String get helpNoMessages => 'Nenhuma mensagem ainda.';

  @override
  String get helpNotSignedIn => 'Você não entrou.';

  @override
  String get helpReload => 'Recarregar';

  @override
  String get helpSend => 'Enviar';

  @override
  String get helpTitle => 'Escreva para a equipe Presence';

  @override
  String homeAskedGrabs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Pedida uma imagem nova a $count dispositivos…',
      one: 'Pedida uma imagem nova a 1 dispositivo…',
      zero: 'Pedida uma imagem nova a todos os dispositivos',
    );
    return '$_temp0';
  }

  @override
  String get homeBatteryCharging => 'carregando';

  @override
  String get homeBatteryFull => 'cheia';

  @override
  String homeBatteryLevel(int level) {
    return 'Bateria $level %';
  }

  @override
  String get homeBatteryOnBattery => 'na bateria';

  @override
  String get homeBatteryPlugged => 'conectada, sem carregar';

  @override
  String homeBatteryTemperature(String temperature) {
    return 'Temperatura da bateria $temperature';
  }

  @override
  String homeBatteryTemperatureHot(String temperature) {
    return 'Temperatura da bateria $temperature, quente';
  }

  @override
  String get homeClipAll => 'Capturar tudo';

  @override
  String get homeClipManual => 'Clipe iniciado';

  @override
  String get homeClipMotion => 'Movimento detectado';

  @override
  String homeClipSaving(String started, int seconds) {
    return '$started · salvando os próximos $seconds s';
  }

  @override
  String get homeClipScheduled => 'Clipe agendado';

  @override
  String get homeClipStartup => 'Clipe de início';

  @override
  String homeJoinedAccount(String email, String deviceId) {
    return 'Este dispositivo agora é de $email: $deviceId';
  }

  @override
  String homeJoinedOpen(String deviceId) {
    return 'Presence está aberto neste dispositivo: $deviceId';
  }

  @override
  String homeMessageTapToView(String label) {
    return '$label. Toque para ver.';
  }

  @override
  String get homeScreenOffHint =>
      'Desatendido: capturando com a tela apagada. Toque para acender.';

  @override
  String homeSignInFailed(String error) {
    return 'Falha ao entrar: $error';
  }

  @override
  String get homeUnattendedWoken =>
      'Desatendido: apaga 15 s após o último toque';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageLabel => 'Idioma do aplicativo';

  @override
  String get languageNote =>
      'Nomes, etiquetas e IDs de dispositivo aparecem como foram escritos.';

  @override
  String get languagePortuguese => 'Português';

  @override
  String get languageSection => 'Idioma';

  @override
  String get languageSpanish => 'Español';

  @override
  String get languageSystem => 'O mesmo do dispositivo';

  @override
  String get logClear => 'Limpar';

  @override
  String get logCopied => 'Log copiado';

  @override
  String get logCopy => 'Copiar';

  @override
  String get logEmpty => 'Nada registrado ainda.';

  @override
  String get logTitle => 'Log';

  @override
  String logTitleCount(int count) {
    return 'Log · últimos $count';
  }

  @override
  String get maintenanceBody =>
      'Voltamos logo. Esta página se atualiza sozinha.';

  @override
  String get maintenanceTitle => 'Desculpe, o Presence está em manutenção.';

  @override
  String get navAdmin => 'Admin';

  @override
  String get navCamera => 'Câmera';

  @override
  String get navHelp => 'Ajuda';

  @override
  String get navHelpTitle => 'Ajuda';

  @override
  String get navLog => 'Log';

  @override
  String get navMonitoring => 'Monitorar';

  @override
  String get navProfile => 'Perfil';

  @override
  String get navSettings => 'Ajustes';

  @override
  String navSignedInAs(String identity) {
    return 'Conectado como $identity';
  }

  @override
  String get settingsAddDeviceCopy => 'Copiar link';

  @override
  String get settingsAddDeviceLinkCopied => 'Link copiado';

  @override
  String settingsAddDeviceQr(String link) {
    return 'Código QR de $link';
  }

  @override
  String get settingsAddDeviceScan =>
      'Escaneie com outro dispositivo para abrir o Presence nele. Ele vira um novo dispositivo, com ID próprio.';

  @override
  String settingsAddDeviceScanAs(String email) {
    return 'Escaneie com outro dispositivo para abrir o Presence nele como $email. Ele vira um novo dispositivo, com ID próprio.';
  }

  @override
  String get settingsAddDeviceShare => 'Compartilhar';

  @override
  String get settingsAddDeviceShareTitle => 'Abrir o Presence';

  @override
  String get settingsAddDeviceTitle => 'Adicionar um dispositivo';

  @override
  String get settingsAdvancedSection => 'Avançado';

  @override
  String get settingsAskNote =>
      'Com menos certeza, pergunta a você se são eles.';

  @override
  String get settingsAutoTag => 'Marcar automaticamente com pelo menos';

  @override
  String settingsAutoTagValue(int percent) {
    return '$percent % de certeza';
  }

  @override
  String get settingsBrightness => 'Brilho';

  @override
  String get settingsCameraSection => 'Câmera';

  @override
  String get settingsClipAfter => 'Depois do toque';

  @override
  String get settingsClipBefore => 'Antes do toque';

  @override
  String settingsClipsNote(int seconds) {
    return 'Os clipes duram $seconds s no total. Mudar \"Antes\" leva até esse tempo para valer, enquanto as câmeras acumulam histórico.';
  }

  @override
  String get settingsClipsSection => 'Clipes';

  @override
  String get settingsCloudFailed =>
      'Não deu para treinar agora; tenta de novo depois.';

  @override
  String settingsCloudLastTrained(String time) {
    return 'Último treino $time';
  }

  @override
  String get settingsCloudNoLabels =>
      'Nada para aprender ainda: marque pessoas e pets.';

  @override
  String get settingsCloudNotPremium =>
      'O reconhecimento na nuvem é só Premium.';

  @override
  String get settingsCloudNotTrained => 'Ainda não treinado';

  @override
  String settingsCloudStatus(String when) {
    return '$when. Aprende com as pessoas e pets que você marca; verificado diariamente.';
  }

  @override
  String get settingsCloudTitle => 'Reconhecimento na nuvem (Premium)';

  @override
  String get settingsCloudTrain => 'Treinar agora';

  @override
  String get settingsCloudTrained => 'Treinado.';

  @override
  String get settingsCloudUpToDate => 'Atualizado.';

  @override
  String get settingsCoordinatesAxes =>
      'Informe uma latitude (N ou S) e uma longitude (L ou O)';

  @override
  String get settingsCoordinatesEmpty => 'Cole uma latitude e longitude';

  @override
  String get settingsCoordinatesInvalid =>
      'Não é uma posição: use latitude, longitude, ex. 38.7223, -9.1393';

  @override
  String get settingsCoordinatesLatitudeRange =>
      'A latitude deve estar entre -90 e 90';

  @override
  String get settingsCoordinatesLongitudeRange =>
      'A longitude deve estar entre -180 e 180';

  @override
  String get settingsCoordinatesMinutes => 'Minutos e segundos vão até 59';

  @override
  String get settingsDeleteDeviceCancel => 'Cancelar';

  @override
  String get settingsDeleteDeviceConfirm => 'Apagar';

  @override
  String settingsDeleteDeviceDone(String deviceId, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count eventos ocultos',
      one: '1 evento oculto',
    );
    return '$deviceId apagado: $_temp0';
  }

  @override
  String settingsDeleteDeviceFailed(String deviceId) {
    return 'Não foi possível apagar $deviceId';
  }

  @override
  String settingsDeleteDeviceMessage(String deviceId, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Seus $count eventos ficarão ocultos',
      one: 'Seu evento ficará oculto',
    );
    return 'Apagar o dispositivo $deviceId? $_temp0 em todos os dispositivos.';
  }

  @override
  String get settingsDeleteDeviceNote =>
      'Os clipes continuam na nuvem. Se ele gravar de novo, volta a aparecer com os novos eventos.';

  @override
  String get settingsDeleteDeviceTitle => 'Apagar dispositivo?';

  @override
  String get settingsDevice => 'Dispositivo';

  @override
  String get settingsDeviceLoading => 'carregando…';

  @override
  String get settingsHistoryNote =>
      'Eventos mais antigos e seus clipes são apagados deste dispositivo ao abrir o app e a cada 3 horas.';

  @override
  String get settingsHistorySection => 'Histórico';

  @override
  String get settingsJoinDismiss => 'Dispensar';

  @override
  String settingsJoinOtherUser(String email) {
    return 'O link foi compartilhado por outra conta Google, não $email. Saia e entre com aquela para adicionar este dispositivo.';
  }

  @override
  String get settingsJoinOtherUserUnknown =>
      'O link foi compartilhado por outra conta Google, não a sua. Saia e entre com aquela para adicionar este dispositivo.';

  @override
  String get settingsJoinSameDevice =>
      'Este é o dispositivo que compartilhou o link. Abra-o em outro dispositivo para adicioná-lo.';

  @override
  String get settingsJoinSignIn =>
      'Para adicionar este dispositivo, entre com a conta Google que compartilhou o link.';

  @override
  String get settingsJoinSignOut => 'Sair';

  @override
  String get settingsKeep => 'Manter eventos por';

  @override
  String settingsKeepDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dias',
      one: '1 dia',
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
      'Sempre conectado para administradores, então este dispositivo está sempre acessível: eventos de outros dispositivos chegam em um segundo.';

  @override
  String get settingsLiveAlways => 'Sempre';

  @override
  String get settingsLiveAlwaysNote =>
      'Fica conectado: eventos de outros dispositivos chegam em um segundo.';

  @override
  String get settingsLiveConnect => 'Conectar à sincronização ao vivo';

  @override
  String settingsLiveEvery(String interval) {
    return 'A cada $interval';
  }

  @override
  String get settingsLiveNever => 'Nunca';

  @override
  String get settingsLiveNeverNote =>
      'Eventos de outros dispositivos chegam a cada sincronização (15 s), e os deste chegam a eles do mesmo jeito.';

  @override
  String settingsLiveScheduledNote(String interval) {
    return 'Conecta a cada $interval aprox. para receber o que outros dispositivos enviaram, e na hora para enviar os eventos deste.';
  }

  @override
  String get settingsLiveSection => 'Sincronização ao vivo';

  @override
  String get settingsLocationDenied => 'A permissão de localização foi negada';

  @override
  String get settingsLocationFinding => 'Localizando este dispositivo…';

  @override
  String settingsLocationMoveMap(String reason) {
    return '$reason. Mova o mapa para defini-la.';
  }

  @override
  String get settingsLocationMyLocation => 'Minha localização';

  @override
  String get settingsLocationOff => 'A localização está desativada';

  @override
  String get settingsLocationPaste => 'Colar posição';

  @override
  String get settingsLocationPin => 'Fixar posição';

  @override
  String get settingsLocationPinThis => 'Fixar esta posição';

  @override
  String get settingsLocationPinnedLabel => 'Fixada:';

  @override
  String get settingsLocationPinnedStatus => 'Fixada · usada em todo evento';

  @override
  String get settingsLocationPositionLabel => 'Posição (latitude, longitude)';

  @override
  String get settingsLocationSection => 'Localização';

  @override
  String get settingsLocationSetOnMap => 'Definida no mapa';

  @override
  String get settingsLocationSetThis => 'Usar esta posição';

  @override
  String get settingsLocationThisDevice => 'Localização deste dispositivo';

  @override
  String get settingsLocationUnavailable => 'Localização indisponível';

  @override
  String get settingsLocationUnknown => 'Localização desconhecida';

  @override
  String get settingsLocationUnpin => 'Desafixar';

  @override
  String get settingsLocationUnpinToLocate =>
      'Desafixe para usar minha localização';

  @override
  String get settingsMapAttribution => '© Colaboradores do OpenStreetMap';

  @override
  String get settingsMapZoomIn => 'Aproximar';

  @override
  String get settingsMapZoomOut => 'Afastar';

  @override
  String get settingsMotionCooldown => 'No máximo um clipe automático a cada';

  @override
  String settingsMotionNow(int percent) {
    return 'Movimento agora: $percent %';
  }

  @override
  String get settingsMotionNowWaiting =>
      'Movimento agora: aguardando a câmera…';

  @override
  String get settingsMotionSection => 'Movimento';

  @override
  String get settingsMotionSwitch => 'Gravar clipe ao detectar movimento';

  @override
  String get settingsMotionThreshold => 'Limite de movimento';

  @override
  String settingsMotionThresholdValue(int percent) {
    return '$percent % da imagem';
  }

  @override
  String get settingsNextClipDue =>
      'Próximo clipe: pendente, quando uma câmera abrir';

  @override
  String settingsNextClipIn(String time) {
    return 'Próximo clipe em $time';
  }

  @override
  String get settingsObjectsSubtitle =>
      'Pessoa, gato, cachorro, bicicleta, garrafa… para busca';

  @override
  String get settingsObjectsSwitch => 'Marcar objetos em clipes novos';

  @override
  String get settingsProfile => 'Perfil';

  @override
  String get settingsProfileNone => 'nenhum até entrar';

  @override
  String get settingsRecognitionSection => 'Reconhecimento';

  @override
  String get settingsRecognitionSubtitle =>
      'Pessoas e pets já marcados, neste dispositivo';

  @override
  String get settingsRecognitionSwitch => 'Reconhecer sujeitos em clipes novos';

  @override
  String get settingsRecognitionUnavailable =>
      'Ainda não disponível neste dispositivo';

  @override
  String get settingsSameAsClip => 'Igual a tocar em Clipe';

  @override
  String get settingsScheduleEvery => 'Um clipe a cada';

  @override
  String get settingsScheduleSection => 'Clipes programados';

  @override
  String get settingsScheduleSwitch =>
      'Gravar clipe ao iniciar e periodicamente';

  @override
  String get settingsShowLog => 'Mostrar a aba Registro';

  @override
  String get settingsShowLogSubtitle =>
      'As últimas mensagens e o estado do app';

  @override
  String get settingsStartupClip =>
      'Clipe inicial: quando a câmera estiver pronta';

  @override
  String get settingsSubjectEvents => 'Quantos eventos carregar de uma vez';

  @override
  String get settingsSubjectsSection => 'Sujeitos';

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
  String get subjectsNoLocation => 'Sem local';

  @override
  String get subjectsNobodyTagged => 'Ninguém está mais marcado com este nome.';

  @override
  String subjectsOpen(String name) {
    return 'Abrir $name';
  }

  @override
  String subjectsOpenEvent(String label) {
    return 'Abrir evento $label';
  }

  @override
  String get subjectsRecognizedAuto => 'Reconhecido automaticamente';
}
