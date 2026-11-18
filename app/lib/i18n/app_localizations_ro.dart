// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Romanian Moldavian Moldovan (`ro`).
class AppLocalizationsRo extends AppLocalizations {
  AppLocalizationsRo([String locale = 'ro']) : super(locale);

  @override
  String get about => 'Despre';

  @override
  String get about_changelog => 'Noutăți';

  @override
  String get about_discord_subtitle => 'Discută cu comunitatea';

  @override
  String get about_github_subtitle => 'Cod sursă, probleme și contribuții';

  @override
  String get about_license => 'Licență';

  @override
  String get about_licenses => 'Licențe open source';

  @override
  String get about_privacy_policy => 'Politica de confidențialitate';

  @override
  String get about_report_bug => 'Raportează o eroare';

  @override
  String about_version(String version) {
    return 'Versiunea $version';
  }

  @override
  String get appearance => 'Aspect';

  @override
  String get account => 'Cont';

  @override
  String get account_delete_confirm =>
      'Ești pe cale să îți ștergi contul. Toate traseele tale vor fi de asemenea șterse. Dorești să continui?';

  @override
  String get account_privacy => 'Confidențialitatea contului';

  @override
  String get add_bio => 'Adaugă descriere';

  @override
  String get add_waypoint => 'Adaugă punct de reper';

  @override
  String get after => 'După';

  @override
  String get all => 'Toate';

  @override
  String get altitude => 'Altitudine';

  @override
  String get author => 'Autor';

  @override
  String get average_speed => 'Viteză medie';

  @override
  String get background_location_body =>
      'wanderer colectează date despre locație în fundal astfel încât traseul tău să continue să fie înregistrat când ecranul este oprit sau aplicația este închisă. Traseul înregistrat rămâne pe dispozitivul tău până alegi să îl salvezi.\n\nAndroid oferă această opțiune doar în setările de sistem: deschide Permisiuni → Locație și alege „Permite întotdeauna”.';

  @override
  String get background_location_confirm => 'Deschide setările';

  @override
  String get background_location_title => 'Continuă înregistrarea în fundal';

  @override
  String get basic_info => 'Informații de bază';

  @override
  String get before => 'Înainte de';

  @override
  String get by => 'de';

  @override
  String get cancel => 'Anulează';

  @override
  String get discard => 'Renunță';

  @override
  String get discard_trail_confirm =>
      'Renunți la acest traseu și la modificările lui?';

  @override
  String card(num n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Carduri',
      few: 'Carduri',
      one: 'Card',
    );
    return '$_temp0';
  }

  @override
  String get categories => 'Categorii';

  @override
  String get category => 'Categorie';

  @override
  String get change_email => 'Schimbă adresa de e-mail';

  @override
  String get change_password => 'Schimbă parola';

  @override
  String get clear_all => 'Șterge tot';

  @override
  String get close => 'Închide';

  @override
  String comment(num n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Comentarii',
      few: 'Comentarii',
      one: 'Comentariu',
    );
    return '$_temp0';
  }

  @override
  String get completed => 'Finalizat';

  @override
  String get completion_status => 'Stare finalizare';

  @override
  String get confirm_deletion => 'Confirmă ștergerea';

  @override
  String get couldnt_start_navigation =>
      'Nu s-a putut porni navigarea. Verifică conexiunea și încearcă din nou.';

  @override
  String get location_services_disabled =>
      'Serviciile de localizare sunt dezactivate. Activează GPS-ul pentru a folosi navigarea.';

  @override
  String get location_permission_denied =>
      'Permisiunea pentru locație este necesară pentru navigare.';

  @override
  String get location_permission_permanently_denied =>
      'Permisiunea pentru locație este refuzată permanent. Activeaz-o din Setări.';

  @override
  String get location_unavailable =>
      'Nu s-a putut determina locația ta. Încearcă din nou.';

  @override
  String get copy_link => 'Copiază linkul';

  @override
  String get create_waypoint => 'Creează punct de reper';

  @override
  String get creation_date => 'Data creării';

  @override
  String get current_password => 'Parola curentă';

  @override
  String get danger_zone => 'Zonă de risc';

  @override
  String get date => 'Dată';

  @override
  String get delete => 'Șterge';

  @override
  String get not_now => 'Nu acum';

  @override
  String get open => 'Deschide';

  @override
  String get delete_account => 'Șterge contul';

  @override
  String get delete_trail_confirm =>
      'Sigur dorești să ștergi acest traseu? Această acțiune nu poate fi anulată.';

  @override
  String get delete_blocked_while_uploading =>
      'Acest traseu se încarcă chiar acum. Așteaptă finalizarea încărcării și încearcă din nou.';

  @override
  String get delete_unsynced_trail_confirm =>
      'Ștergi acest traseu? Încă nu a fost încărcat pe server, deci acțiunea nu poate fi anulată.';

  @override
  String get delete_needs_connection =>
      'Acest traseu este deja pe server. Conectează-te la internet pentru a-l șterge.';

  @override
  String get description => 'Descriere';

  @override
  String get difficult => 'Dificil';

  @override
  String get difficulty => 'Dificultate';

  @override
  String get directions => 'Indicații';

  @override
  String get distance => 'Distanță';

  @override
  String get download => 'Descarcă';

  @override
  String get duration => 'Durată';

  @override
  String get easy => 'Ușor';

  @override
  String get edit => 'Editează';

  @override
  String get edit_needs_connection =>
      'Editarea funcționează pe copia de pe server a acestui traseu. Conectează-te la internet pentru a-l edita.';

  @override
  String get edit_waypoint => 'Editează punctul de reper';

  @override
  String get edited => 'editat';

  @override
  String get elevation_gain => 'Diferență de nivel (+)';

  @override
  String get elevation_loss => 'Coborâre (-)';

  @override
  String get elevation_profile => 'Profil de altitudine';

  @override
  String get email => 'E-mail';

  @override
  String get email_not_unique => 'Această adresă de e-mail este deja folosită.';

  @override
  String get email_updated => 'E-mail actualizat';

  @override
  String get error_deleting_trail => 'Eroare la ștergerea traseului';

  @override
  String get error_reading_file => 'Eroare la citirea fișierului';

  @override
  String get error_saving_settings => 'Eroare la salvarea setărilor';

  @override
  String get error_saving_trail => 'Eroare la salvarea traseului';

  @override
  String get error_updating_password => 'Eroare la actualizarea parolei';

  @override
  String get explore => 'Explorează';

  @override
  String get exit_navigation => 'Ieșire';

  @override
  String get stop_navigation_confirm => 'Oprești navigarea și revii la traseu?';

  @override
  String get stop_recording => 'Oprește înregistrarea';

  @override
  String get stop_recording_confirm => 'Oprești înregistrarea?';

  @override
  String get search_this_area => 'Caută în această zonă';

  @override
  String get filter_category_deselect_hint =>
      'Apasă lung pentru a deselecta o categorie';

  @override
  String get filter_tags => 'Filtrează etichete';

  @override
  String get filter_trails => 'Filtrează traseele';

  @override
  String get finish => 'Final';

  @override
  String get finish_disabled_hint =>
      'Adaugă cel puțin 2 puncte de ancorare pentru a finaliza ruta.';

  @override
  String get follow => 'Urmărește';

  @override
  String get followers => 'Urmăritori';

  @override
  String get following => 'Urmăriri';

  @override
  String get from_photos => 'Din fotografii';

  @override
  String get help => 'Ajutor';

  @override
  String get hiking => 'Drumeție';

  @override
  String get home => 'Acasă';

  @override
  String get icon => 'Pictogramă';

  @override
  String get imperial => 'Imperial';

  @override
  String get joined => 'Membru din';

  @override
  String get language => 'Limbă';

  @override
  String get latitude => 'Latitudine';

  @override
  String get like_status => 'Stare apreciere';

  @override
  String get liked => 'Apreciate';

  @override
  String get likes => 'Aprecieri';

  @override
  String list(num n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Liste',
      few: 'Liste',
      one: 'Listă',
    );
    return '$_temp0';
  }

  @override
  String get location => 'Locație';

  @override
  String get locations => 'Locații';

  @override
  String get center_on_my_location => 'Centrează pe locația mea';

  @override
  String get location_tracking_notification_title => 'wanderer';

  @override
  String get location_tracking_notification_text => 'Se înregistrează traseul';

  @override
  String location_tracking_notification_text_navigating(String trail) {
    return 'Navigare: $trail';
  }

  @override
  String get login => 'Autentificare';

  @override
  String get logout => 'Deconectare';

  @override
  String get longitude => 'Longitudine';

  @override
  String get map => 'Hartă';

  @override
  String get metric => 'Metric';

  @override
  String get moderate => 'Mediu';

  @override
  String get my_account => 'Contul meu';

  @override
  String in_distance(String distance) {
    return 'peste $distance';
  }

  @override
  String get name => 'Nume';

  @override
  String get navigate => 'Navighează';

  @override
  String get new_password => 'Parolă nouă';

  @override
  String get new_password_success => 'Noua parolă a fost setată';

  @override
  String get new_trail => 'Traseu nou';

  @override
  String get trail_source_planner => 'Deschide planificatorul de trasee';

  @override
  String get trail_source_planner_description =>
      'Desenează o rută nouă pe hartă, punct cu punct.';

  @override
  String get trail_source_record => 'Înregistrează traseu';

  @override
  String get trail_source_record_description =>
      'Urmărește coordonatele live și înregistrează parcursul în timp real.';

  @override
  String get trail_source_import => 'Importă fișier';

  @override
  String get trail_source_import_description =>
      'Încarcă fișiere GPX, KML, KMZ, TCX sau FIT direct din memoria dispozitivului.';

  @override
  String get trail_source_import_error => 'Fișierul nu a putut fi importat';

  @override
  String get trail_source_offline_import_error =>
      'Offline pot fi importate doar fișiere GPX';

  @override
  String get no_comments_so_far => 'Niciun comentariu până acum';

  @override
  String get no_data => 'Fără date';

  @override
  String get no_description_for_now => 'Nicio descriere momentan';

  @override
  String get no_gps_data_in_image =>
      'Nu s-au găsit date GPS în această fotografie.';

  @override
  String get no_preference => 'Fără preferință';

  @override
  String get no_trails_found => 'Niciun traseu găsit';

  @override
  String get not_completed => 'Nefinalizat';

  @override
  String get notifications => 'Notificări';

  @override
  String get only_me => 'Doar eu';

  @override
  String get or => 'sau';

  @override
  String get own_trails_empty_body =>
      'Traseele pe care le înregistrezi sau le salvezi offline apar aici și se încarcă automat când revii online.';

  @override
  String get own_trails_empty_title => 'Nimic salvat încă';

  @override
  String get own_trails_offline_banner =>
      'Offline — se afișează doar traseele de pe acest dispozitiv.';

  @override
  String get trails_on_device => 'Trasee (pe dispozitiv)';

  @override
  String get pause => 'Pauză';

  @override
  String get password => 'Parolă';

  @override
  String get password_confirm => 'Confirmă parola';

  @override
  String get passwords_must_match => 'Parolele trebuie să coincidă';

  @override
  String photo_copy_failed_toast(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Traseu salvat, dar $count de fotografii nu au putut fi salvate.',
      few: 'Traseu salvat, dar $count fotografii nu au putut fi salvate.',
      one: 'Traseu salvat, dar o fotografie nu a putut fi salvată.',
    );
    return '$_temp0';
  }

  @override
  String get photos => 'Fotografii și videoclipuri';

  @override
  String photos_skipped_no_gps(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de fotografii omise — lipsesc datele GPS',
      few: '$count fotografii omise — lipsesc datele GPS',
      one: '1 fotografie omisă — lipsesc datele GPS',
    );
    return '$_temp0';
  }

  @override
  String get privacy => 'Confidențialitate';

  @override
  String get private => 'Privat';

  @override
  String get profile => 'Profil';

  @override
  String get public => 'Public';

  @override
  String get reached_end_of_trail => 'Ai ajuns la capătul traseului.';

  @override
  String get register => 'Înregistrare';

  @override
  String get reorder_photos_hint =>
      'Apasă lung și trage pentru a reordona fotografiile.';

  @override
  String get reset => 'Resetează';

  @override
  String get resume => 'Reia';

  @override
  String resume_navigation_prompt(String trail) {
    return 'Reiei navigarea pe $trail?';
  }

  @override
  String get resume_recording_prompt => 'Reiei înregistrarea?';

  @override
  String route(num n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Rute',
      few: 'Rute',
      one: 'Rută',
    );
    return '$_temp0';
  }

  @override
  String get follow_roads => 'Urmează drumurile';

  @override
  String get follow_roads_description =>
      'Aliniază traseul înregistrat la cele mai apropiate drumuri și poteci.';

  @override
  String get recalculate_heights => 'Recalculează altitudinile';

  @override
  String get recalculate_heights_description =>
      'Înlocuiește altitudinea GPS înregistrată cu valori mai precise de pe hartă.';

  @override
  String get track_transform_failed =>
      'Traseul nu a putut fi ajustat. Verifică conexiunea și încearcă din nou.';

  @override
  String get save => 'Salvează';

  @override
  String get save_track => 'Salvează parcursul';

  @override
  String get search => 'Caută';

  @override
  String get search_for_trails_places => 'Caută trasee, liste, locuri';

  @override
  String get select_date => 'Selectează data';

  @override
  String get settings => 'Setări';

  @override
  String get settings_notification_comment_mention =>
      'Cineva te-a menționat într-un comentariu';

  @override
  String get settings_notification_list_share =>
      'Cineva a partajat o listă cu tine';

  @override
  String get settings_notification_new_follower => 'Ai un urmăritor nou';

  @override
  String get settings_notification_summit_log_create =>
      'Cineva a adăugat o însemnare de vârf la traseul tău';

  @override
  String get settings_notification_summit_log_mention =>
      'Cineva te-a menționat într-o însemnare de vârf';

  @override
  String get settings_notification_trail_comment =>
      'Cineva a lăsat un comentariu la traseul tău';

  @override
  String get settings_notification_trail_like =>
      'Cineva a apreciat traseul tău';

  @override
  String get settings_notification_trail_mention =>
      'Cineva te-a menționat într-un traseu';

  @override
  String get settings_notification_trail_share =>
      'Cineva a partajat un traseu cu tine';

  @override
  String get settings_privacy_account_private =>
      'Doar tu îți poți vedea profilul. Nu vei apărea în rezultatele căutării. Alți utilizatori nu te pot urmări și nu îți pot partaja trasee. Poți publica în continuare trasee sau liste.';

  @override
  String get settings_privacy_account_public =>
      'Oricine îți poate vedea profilul. Apari în rezultatele căutării. Alți utilizatori te pot urmări și îți pot partaja trasee.';

  @override
  String get settings_privacy_lists_private =>
      'Listele tale sunt private în mod implicit. Nimeni în afară de tine nu le va putea vedea. Poți schimba această setare oricând pentru fiecare listă în parte.';

  @override
  String get settings_privacy_lists_public =>
      'Listele tale sunt publice în mod implicit. Oricine le va putea vedea. Poți schimba această setare oricând pentru fiecare listă în parte.';

  @override
  String get settings_privacy_trails_private =>
      'Traseele tale sunt private în mod implicit. Nimeni în afară de tine nu le va putea vedea. Poți schimba această setare oricând pentru fiecare traseu în parte.';

  @override
  String get settings_privacy_trails_public =>
      'Traseele tale sunt publice în mod implicit. Oricine le va putea vedea. Poți schimba această setare oricând pentru fiecare traseu în parte.';

  @override
  String get share => 'Partajează';

  @override
  String get share_profile => 'Partajează profilul';

  @override
  String get shared => 'Partajate';

  @override
  String get shortcut_new_trail => 'Traseu nou';

  @override
  String get show_on_map => 'Afișează pe hartă';

  @override
  String signout_unsynced_warning(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Ai $count de trasee neîncărcate încă. Deconectarea nu le va șterge — vor rămâne aici când te reconectezi — dar nu vor fi încărcate până atunci.',
      few:
          'Ai $count trasee neîncărcate încă. Deconectarea nu le va șterge — vor rămâne aici când te reconectezi — dar nu vor fi încărcate până atunci.',
      one: 'Ai 1 traseu neîncărcat încă. Deconectarea nu îl va șterge — va rămâne aici când te reconectezi — dar nu va fi încărcat până atunci.',
    );
    return '$_temp0';
  }

  @override
  String get slogan => 'Traseele tale. Datele tale. Serverul tău.';

  @override
  String get sort => 'Sortează';

  @override
  String get speed => 'Viteză';

  @override
  String get start => 'Start';

  @override
  String get subcategories => 'Subcategorii';

  @override
  String get summit_book => 'Jurnal de vârf';

  @override
  String get sync_discard_draft_confirm =>
      'Ștergi această înregistrare? Nu a fost încărcată nicăieri.';

  @override
  String get sync_draft => 'Ciornă';

  @override
  String get sync_failed => 'Încărcare eșuată · Atinge pentru a reîncerca';

  @override
  String get sync_pending => 'În așteptarea încărcării';

  @override
  String get sync_section_failed_body =>
      'Încărcarea nu a reușit. Încearcă din nou.';

  @override
  String get sync_section_pending_online_body =>
      'Se încarcă automat în câteva clipe.';

  @override
  String get sync_section_uploading_body =>
      'Se trimite acest traseu către serverul tău.';

  @override
  String get sync_section_draft_body =>
      'Această înregistrare există doar pe acest dispozitiv.';

  @override
  String get sync_section_draft_title => 'Încă neîncărcat';

  @override
  String get sync_section_failed_title => 'Încărcare eșuată';

  @override
  String get sync_section_pending_offline_body =>
      'Se va încărca când revii online';

  @override
  String get sync_section_retry => 'Reîncearcă';

  @override
  String get sync_section_upload => 'Încarcă';

  @override
  String get sync_section_upload_now => 'Încarcă acum';

  @override
  String get sync_uploading => 'Se încarcă…';

  @override
  String get tags => 'Etichete';

  @override
  String get theme_dark => 'Întunecat';

  @override
  String get theme_light => 'Luminos';

  @override
  String get theme_system => 'Urmează sistemul';

  @override
  String get time_in_motion => 'Timp în mișcare';

  @override
  String trail(num n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Trasee',
      few: 'Trasee',
      one: 'Traseu',
    );
    return '$_temp0';
  }

  @override
  String get trail_saved_successfully => 'Traseul a fost salvat';

  @override
  String get trail_not_on_this_device =>
      'Acest traseu nu se mai află pe acest dispozitiv.';

  @override
  String get trail_uploaded_reopen_to_edit =>
      'Acest traseu s-a încărcat. Redeschide-l din traseele tale pentru a continua editarea.';

  @override
  String get some_waypoints_failed_to_save =>
      'Traseu salvat, dar unele puncte de reper nu au putut fi salvate';

  @override
  String get units => 'Unități de măsură';

  @override
  String get users => 'Utilizatori';

  @override
  String get username => 'Nume de utilizator';

  @override
  String get username_not_unique =>
      'Acest nume de utilizator este deja folosit. Încearcă altul.';

  @override
  String get visibilty_status => 'Stare vizibilitate';

  @override
  String get web => 'Web';

  @override
  String waypoints(num n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Puncte de reper',
      few: 'Puncte de reper',
      one: 'Punct de reper',
    );
    return '$_temp0';
  }

  @override
  String get welcome_to => 'Bun venit pe';

  @override
  String get wrong_username_or_password =>
      'Nume de utilizator sau parolă incorectă';

  @override
  String get oauth_provider_unavailable =>
      'Acest server nu mai oferă această opțiune de autentificare.';

  @override
  String get oauth_login_rate_limited =>
      'Prea multe încercări de autentificare din rețeaua ta. Încearcă din nou într-un minut.';

  @override
  String oauth_login_rate_limited_seconds(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds de secunde',
      few: '$seconds secunde',
      one: 'o secundă',
    );
    return 'Prea multe încercări de autentificare din rețeaua ta. Încearcă din nou în $_temp0.';
  }

  @override
  String get oauth_login_server_unavailable =>
      'Serverul este temporar indisponibil. Încearcă să te autentifici mai târziu.';

  @override
  String get oauth_login_rejected =>
      'Serverul nu a putut iniția această autentificare. Încearcă din nou și actualizează aplicația dacă eroarea persistă.';

  @override
  String get server_incompatible_title => 'Server incompatibil';

  @override
  String get server_incompatible =>
      'Acest server rulează o versiune de wanderer pe care aplicația nu o suportă. Autentificarea va fi posibilă după actualizarea serverului.';

  @override
  String server_incompatible_version(String version) {
    return 'Versiune server: $version';
  }

  @override
  String get server_incompatible_docs => 'Cum să actualizezi serverul';

  @override
  String get you_have_arrived => 'Ai ajuns la destinație';

  @override
  String get settings_categories_confirm_disable_title =>
      'Ascunzi această categorie?';

  @override
  String get settings_categories_confirm_disable_subcategory_title =>
      'Ascunzi această subcategorie?';

  @override
  String settings_categories_confirm_disable_body(int count) {
    return '$count dintre traseele tale folosesc această categorie. Vor rămâne publicate, dar acest filtru va fi ascuns.';
  }

  @override
  String get settings_categories_confirm_view_trails => 'Vezi traseele';

  @override
  String get settings_categories_confirm_disable_confirm =>
      'Dezactivează oricum';

  @override
  String get settings_categories_empty_title => 'Fără subcategorii';

  @override
  String get settings_categories_empty_body =>
      'Această categorie nu are subcategorii de configurat.';

  @override
  String get settings_categories_reorder_hint =>
      'Categoriile controlează ce tipuri de trasee vezi și în ce ordine. Dezactivează una pentru a o ascunde ca filtru — traseele tale rămân publicate, doar că nu vor mai apărea sub acea categorie. Atinge o categorie pentru a-i gestiona individual subcategoriile.\n\nPentru a schimba ordinea, apasă lung un rând și trage-l în noua poziție. Ordinea setată aici se aplică peste tot unde sunt afișate categoriile.';

  @override
  String get something_went_wrong => 'Ceva nu a mers bine';

  @override
  String get technical_details => 'Detalii tehnice';

  @override
  String get link => 'Link';

  @override
  String get url => 'URL';

  @override
  String get open_in_new_tab => 'Deschide într-o filă nouă';

  @override
  String get remove => 'Elimină';

  @override
  String get remove_download_confirm_body =>
      'Această acțiune elimină copia descărcată de pe acest dispozitiv. Traseul în sine nu este șters — va trebui să îl descarci din nou pentru a-l folosi offline.';

  @override
  String get apply => 'Aplică';

  @override
  String get add_at_least_2_anchors_hint =>
      'Adaugă cel puțin 2 puncte de ancorare pentru a vedea profilul de altitudine.';

  @override
  String get reverse_direction => 'Inversează direcția';

  @override
  String get delete_all => 'Șterge tot';

  @override
  String get auto_routing => 'Rutare automată';

  @override
  String get auto_routing_hint =>
      'Urmează automat drumurile și potecile între punctele de ancorare.';

  @override
  String get travel_profile => 'Profil de deplasare';

  @override
  String get no_elevation_data => 'Fără date de altitudine';

  @override
  String get available_offline => 'Disponibil offline';

  @override
  String get no_lists_found => 'Nicio listă găsită';

  @override
  String get search_lists => 'Caută liste…';

  @override
  String get search_for_a_location => 'Caută o locație';

  @override
  String no_results_for_query(String query) {
    return 'Niciun rezultat pentru „$query”';
  }

  @override
  String get filter => 'Filtrează';

  @override
  String get no_bio_yet => 'Nicio descriere încă.';

  @override
  String get show_more => 'Afișează mai mult';

  @override
  String get show_less => 'Afișează mai puțin';

  @override
  String get feed => 'Flux';

  @override
  String get profile_feed_empty_own => 'Nu ai încă nicio activitate.';

  @override
  String profile_feed_empty_other(String username) {
    return '$username nu are încă nicio activitate.';
  }

  @override
  String get find_people => 'Găsește persoane';

  @override
  String get profile_trails_empty_other_title =>
      'Încă nu există trasee publice';

  @override
  String profile_trails_empty_other_body(String username) {
    return 'Traseele pe care $username le face publice vor apărea aici.';
  }

  @override
  String get profile_lists_empty_own_title => 'Nicio listă încă';

  @override
  String get profile_lists_empty_own_body =>
      'Listele grupează traseele în colecții, cum ar fi o tură de mai multe zile sau favoritele tale locale. Le poți crea în aplicația web.';

  @override
  String get profile_lists_empty_other_title => 'Încă nu există liste publice';

  @override
  String profile_lists_empty_other_body(String username) {
    return 'Listele pe care $username le face publice vor apărea aici.';
  }

  @override
  String get profile_following_empty_title => 'Nu urmărești pe nimeni încă';

  @override
  String get profile_following_empty_own_body =>
      'Urmărește persoane pentru a fi la curent cu cele mai noi trasee publice ale lor, inclusiv de pe alte instanțe.';

  @override
  String profile_following_empty_other_body(String username) {
    return 'Conturile pe care le urmărește $username vor apărea aici.';
  }

  @override
  String get profile_followers_empty_title => 'Niciun urmăritor încă';

  @override
  String get profile_followers_empty_own_body =>
      'Persoanele care te urmăresc vor apărea aici și vor fi la curent cu cele mai noi trasee publice ale tale.';

  @override
  String profile_followers_empty_other_body(String username) {
    return 'Persoanele care îl urmăresc pe $username vor apărea aici.';
  }

  @override
  String get library_empty_title => 'Niciun traseu descărcat';

  @override
  String get library_empty_body =>
      'Traseele pe care le descarci sunt păstrate aici pentru a le putea deschide offline.';

  @override
  String get library_empty_search_body =>
      'Încearcă un alt termen de căutare sau șterge filtrele.';

  @override
  String get search_location => 'Caută locația';

  @override
  String no_servers_match_query(String query) {
    return 'Niciun server nu corespunde pentru „$query”';
  }

  @override
  String get use_custom_url_instead => 'Folosește un URL personalizat';

  @override
  String get select_instance => 'Selectează instanța';

  @override
  String get enter_server_url_hint =>
      'Introdu URL-ul serverului (ex. maps.skillfy.ro)';

  @override
  String get last_used => 'Ultima utilizare';

  @override
  String get community_instances => 'Instanțe ale comunității';

  @override
  String get search_library => 'Caută în bibliotecă…';

  @override
  String language_and_units(String language, String units) {
    return '$language și $units';
  }

  @override
  String get edit_route => 'Editează ruta';

  @override
  String get undo => 'Anulează';

  @override
  String get redo => 'Refă';

  @override
  String get bold => 'Îngroșat';

  @override
  String get italic => 'Cursiv';

  @override
  String get underline => 'Subliniat';

  @override
  String get bullet_list => 'Listă cu marcatori';

  @override
  String get ordered_list => 'Listă numerotată';

  @override
  String get blockquote => 'Citat';

  @override
  String get library => 'Bibliotecă';

  @override
  String get settings_offline_regions_title => 'Hărți / Regiuni offline';

  @override
  String get regions_search_hint => 'Caută regiuni';

  @override
  String get regions_dem_toggle_label => 'Descarcă date de altitudine (DEM)';

  @override
  String get regions_dem_toggle_caption =>
      'Adaugă umbrire a reliefului; mărește dimensiunea descărcării';

  @override
  String get regions_update_available => 'Actualizare disponibilă';

  @override
  String get regions_update_action => 'Actualizează';

  @override
  String get regions_retry => 'Reîncearcă';

  @override
  String get regions_not_yet_available => 'Indisponibil momentan';

  @override
  String get regions_build_failed => 'Generarea a eșuat';

  @override
  String regions_delete_confirm_title(String name) {
    return 'Ștergi $name?';
  }

  @override
  String get regions_delete_confirm_body =>
      'Această acțiune elimină harta și datele de altitudine descărcate pentru această regiune. Va trebui să le descarci din nou pentru a le folosi offline.';

  @override
  String get regions_delete_confirm_action => 'Șterge';

  @override
  String regions_disk_usage_summary(String size, num count) {
    return '$size utilizați pentru $count regiuni descărcate';
  }

  @override
  String get regions_empty_search_title => 'Nicio regiune potrivită';

  @override
  String get regions_empty_search_body => 'Încearcă un alt termen de căutare.';

  @override
  String get regions_empty_catalog_title => 'Nicio regiune offline disponibilă';

  @override
  String get regions_empty_catalog_body =>
      'Solicită administratorului instanței Wanderer să configureze regiuni descărcabile.';

  @override
  String get regions_vector_tile_title => 'Vector';

  @override
  String get regions_dem_tile_title => 'Date de altitudine';

  @override
  String get regions_download_failed => 'Descărcare eșuată';

  @override
  String get regions_dem_locked_subtitle => 'Descarcă mai întâi datele hărții';

  @override
  String get regions_offline_unavailable_title => 'Nu se pot încărca regiunile';

  @override
  String get regions_offline_unavailable_body =>
      'Conectează-te la internet pentru a răsfoi și gestiona regiunile descărcabile.';

  @override
  String get regions_map_geometry_failed =>
      'Nu s-a putut încărca conturul regiunii';

  @override
  String get regions_map_back_label => 'Înapoi la regiuni';

  @override
  String regions_group_expand_label(String name) {
    return 'Extinde $name';
  }

  @override
  String regions_group_collapse_label(String name) {
    return 'Restrânge $name';
  }

  @override
  String get offline_title => 'Ești offline';

  @override
  String get offline_try_again => 'Încearcă din nou';

  @override
  String get offline_map_body =>
      'Conectează-te la internet pentru a încărca harta. Traseele descărcate sunt încă disponibile.';

  @override
  String get offline_list_body =>
      'Conectează-te la internet pentru a încărca listele.';

  @override
  String get offline_profile_body =>
      'Conectează-te la internet pentru a-ți încărca profilul complet.';

  @override
  String get offline_settings_banner =>
      'Ești offline. Setările sunt doar pentru citire până la reconectare.';

  @override
  String get offline_action_unavailable =>
      'Ești offline — încearcă din nou după ce revii online.';

  @override
  String get offline_categories_body =>
      'Conectează-te la internet pentru a gestiona categoriile.';

  @override
  String get offline_trail_search_body =>
      'Conectează-te la internet pentru a căuta trasee. Traseele descărcate sunt încă disponibile.';

  @override
  String get selected_location => 'Locație selectată';

  @override
  String distance_from_your_location(String distance) {
    return 'La $distance de locația ta';
  }

  @override
  String get plan_route_from_here => 'Planifică o rută de aici';

  @override
  String get recent_searches => 'Căutări recente';

  @override
  String get clear_search_history => 'Șterge istoricul căutărilor';

  @override
  String get clear_search_history_confirm => 'Elimini toate căutările recente?';

  @override
  String get nav_remaining => 'Rămas';

  @override
  String get nav_arrival => 'Sosire';

  @override
  String get nav_climb_left => 'Urcare rămasă';

  @override
  String get nav_off_trail_title => 'În afara traseului';

  @override
  String nav_rejoin_in(String distance) {
    return 'Revenire în $distance';
  }

  @override
  String get nav_min_climb => 'Urcare minimă';

  @override
  String get nav_shortest_path => 'Drum minim';

  @override
  String nav_next_summit(String elevation, String distance) {
    return 'Vârf $elevation · peste $distance';
  }
}
