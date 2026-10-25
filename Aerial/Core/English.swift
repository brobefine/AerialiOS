import Foundation

/// Английский перевод строк интерфейса: ключ — русский текст из кода ([L]). Строки с подстановками — с `%@`.
enum English {
    /// Формы слов для [Format.plural]: русская форма «один» → английские «один» и «много».
    static let plural: [String: (String, String)] = [
        "день": ("day", "days"), "раздача": ("torrent", "torrents"), "голос": ("vote", "votes"),
        "видеофайл": ("video file", "video files"), "серия": ("episode", "episodes"), "сезон": ("season", "seasons"),
        "отзыв": ("review", "reviews"), "фильм": ("film", "films"), "минута": ("minute", "minutes"),
        "значение": ("value", "values"), "файл": ("file", "files"),
    ]

    static let table: [String: String] = [
        // Вкладки и общее
        "Главная": "Home", "Медиатека": "Library", "Настройки": "Settings", "Поиск": "Search",
        "Проверка воспроизведения": "Playback check", "Некорректный ответ сервера": "Invalid server response",
        "Встроенный": "Built-in", "Внешний": "External",
        "Народный выбор. Взвешенная оценка зрителей со всего мира по 10-балльной шкале.":
            "The audience choice. A weighted rating from viewers worldwide, out of 10.",
        "Процент положительных оценок: 🍅 — кинокритики, 🍿 — обычные зрители.":
            "Percentage of positive ratings: 🍅 critics, 🍿 audiences.",
        "Оценка критиков: средневзвешенное рецензий ведущих изданий из 100.":
            "Critics' score: a weighted average of reviews from leading outlets, out of 100.",
        "Выбор синефилов. Оценка сообщества любителей кино по 5-балльной шкале.":
            "The cinephile choice. A rating from the film enthusiast community, out of 5.",
        // Каталог
        "В тренде сегодня": "Trending today", "В тренде за неделю": "Trending this week", "Популярное": "Popular",
        "Сейчас в кино": "Now in cinemas", "Скоро в кино": "Coming to cinemas", "Высокие оценки": "Top rated",
        "Сериалы в тренде сегодня": "Series trending today", "Популярные сериалы": "Popular series",
        "Новые серии сегодня": "New episodes today", "Сериалы в эфире": "Series on air", "Лучшие сериалы": "Top rated series",
        "Скоро премьера": "Premieres soon", "Популярные мультфильмы": "Popular animated films",
        "Новые мультфильмы": "New animated films", "Популярные мультсериалы": "Popular animated series",
        "Новые мультсериалы": "New animated series", "Лучшие мультсериалы": "Top rated animated series",
        "Автор": "Creator", "Режиссёр": "Director", "Продолжается": "Returning", "Завершён": "Ended", "Отменён": "Cancelled",
        "В производстве": "In production", "Анонсирован": "Announced", "Франшиза": "Franchise",
        "Оригинальное название": "Original title", "Премьера": "Release", "Страны": "Countries", "Студии": "Studios",
        "Бюджет": "Budget", "Сборы": "Box office", "Сезонов": "Seasons", "Серий": "Episodes",
        "Почти досмотрено": "Almost finished", "Осталось %@": "%@ left",
        "Всё": "All", "Фильмы": "Films", "Сериалы": "Series", "Мультфильмы": "Animated films", "Мультсериалы": "Animated series",
        "Фильм": "Film", "Мультфильм": "Animated film", "Сериал": "Series", "Мультсериал": "Animated series",
        "Серия %@": "Episode %@", "Сезон %@": "Season %@", "Сезон %@, серия %@ · %@": "Season %@, episode %@ · %@",
        "%@ мин": "%@ min", "%@ ч": "%@ h", "%@ ч %@ мин": "%@ h %@ min",
        // Субтитры и плеер
        "Лимит скачиваний OpenSubtitles на сегодня исчерпан": "OpenSubtitles download limit for today is reached",
        "OpenSubtitles не дал ссылку на файл": "OpenSubtitles returned no file link", "OpenSubtitles ответил %@": "OpenSubtitles replied %@",
        "Дорожка %@": "Track %@",
        "Запускаю TorrServer…": "Starting TorrServer…", "Получаю раздачу…": "Getting the torrent…",
        "Жду список файлов…": "Waiting for the file list…", "Не удалось воспроизвести: %@": "Could not play: %@",
        "Открыть комнату": "Open a room", "Пропустить «Ранее в сериале»": "Skip recap", "Пропустить заставку": "Skip intro",
        "Далее": "Up next", "Скрыть": "Hide", "Смотреть": "Watch", "Подготовка к просмотру": "Getting ready",
        "Закрыть": "Close", "Назад на 10 с": "Back 10 s", "Вперёд на 10 с": "Forward 10 s", "Картинка в картинке": "Picture in Picture", "Следующая серия": "Next episode",
        "Звук": "Audio", "Скорость": "Speed", "Обычная": "Normal", "Субтитры": "Subtitles", "Выключены": "Off",
        "Найти субтитры…": "Find subtitles…", "Звук, субтитры и скорость": "Audio, subtitles and speed",
        "Ищу на OpenSubtitles…": "Searching OpenSubtitles…", "Субтитров не нашлось": "No subtitles found", "Отмена": "Cancel",
        "%@ хочет смотреть вместе": "%@ wants to watch together", "Начнётся через %@ с": "Starts in %@ s",
        "%@/с · пиров: %@": "%@/s · peers: %@", "Скачиваний: %@": "Downloads: %@", "Субтитры · %@": "Subtitles · %@",
        // Комнаты и друзья
        "Смотреть вместе": "Watch together", "Готово": "Done", "Создать комнату с этим фильмом": "Create a room with this film",
        "Видео не передаётся: у каждого раздача качается своим TorrServer, через комнату идут только пауза, перемотка, чат и реакции.":
            "Video isn't shared: everyone streams the torrent with their own TorrServer; the room only syncs pause, seeking, chat and reactions.",
        "Войти по коду": "Join with a code", "Код комнаты": "Room code", "Войти": "Join", "Комната": "Room", "Связь": "Connection",
        "Зрители": "Viewers", "Комната смотрит другой файл — плеер переключится на него.": "The room is watching another file — the player will switch to it.",
        "Реакции": "Reactions", "Чат": "Chat", "Вы": "You", "Сообщение": "Message", "Выйти из комнаты": "Leave the room",
        "Подключаюсь…": "Connecting…", "Есть": "Connected", "Есть · пинг %@ мс": "Connected · ping %@ ms", "Ваш код": "Your code",
        "Отправить код": "Share code", "Смотрим вместе в Aerial — код комнаты %@": "Let's watch together in Aerial — room code %@",
        "Мой код в Aerial: %@": "My Aerial code: %@",
        "Друзья добавляются по кодам. Видно, кто в сети и что смотрит; в открытую комнату можно войти сразу.":
            "Friends are added by code. You can see who's online and what they're watching, and join an open room right away.",
        "Друзья": "Friends", "Пока никого": "No one yet", "Постучаться": "Knock",
        "%@ увидит, что вы хотите смотреть вместе.": "%@ will see that you want to watch together.",
        "Войти в комнату %@": "Join room %@", "Удалить": "Delete", "Добавить друга": "Add a friend",
        "Код друга (6 символов)": "Friend's code (6 characters)", "Имя (необязательно)": "Name (optional)", "Добавить": "Add",
        "Код не подошёл: нужно 6 символов, и не свой.": "That code doesn't work: it must be 6 characters and not your own.",
        "в сети": "online", "не в сети": "offline", "PIN для другого устройства": "PIN for another device",
        "Добавить своё устройство": "Add my device", "сервер недоступен": "server unavailable",
        "PIN с другого устройства": "PIN from another device", "Устройство в аккаунте.": "The device is in the account.",
        "PIN не подошёл.": "The PIN doesn't match.", "Отвязать это устройство": "Unlink this device", "Мои устройства": "My devices",
        "Телефон, ТВ и компьютер можно объединить: у них будет общий код и общий список друзей.":
            "Link your phone, TV and computer: they will share one code and one friends list.",
        "Войти в комнату": "Join the room", "Вы в комнате": "You're in the room", "Жду фильм от комнаты…": "Waiting for the room's film…",
        "Неверный код": "Wrong code", "Комнаты недоступны (ключ)": "Rooms unavailable (key)", "Комната заполнена": "The room is full",
        "Нет связи с комнатой, переподключаемся…": "Lost the room, reconnecting…", "входит в комнату": "joins the room",
        "выходит из комнаты": "leaves the room", "ставит на паузу": "pauses", "продолжает просмотр": "resumes",
        "перематывает": "seeks", "включает ": "switches to ",
        // Загрузки
        "Загружено · можно смотреть без сети": "Downloaded · watch offline",
        "Загрузка на паузе · откройте Aerial, чтобы продолжить": "Download paused · open Aerial to continue",
        "Aerial · загрузки": "Aerial · downloads", "Загрузка: %@": "Downloading: %@", "На паузе · %@ %": "Paused · %@ %",
        "осталось %@": "%@ left", "%@ % · %@/с": "%@ % · %@/s", "В раздаче нет видеофайлов": "The torrent has no video files",
        "Не хватает места: нужно %@, свободно %@": "Not enough space: %@ needed, %@ free", "Прервано в фоне": "Interrupted in the background",
        "Загрузка прервалась: %@": "The download stopped: %@", "файл оборвался: %@ из %@ МБ": "file cut short: %@ of %@ MB",
        "сервер не отвечает — перезапустите приложение": "the server isn't responding — restart the app",
        "сервер не отвечает": "the server isn't responding", "Некорректный адрес TorrServer": "Invalid TorrServer address",
        "Некорректная ссылка на раздачу": "Invalid torrent link",
        "Раздача не ответила: нет сидов или трекеры недоступны": "The torrent didn't respond: no seeders or trackers unavailable",
        "TorrServer не запущен: %@": "TorrServer isn't running: %@",
        "Загрузки": "Downloads", "Продолжить": "Continue", "Повторить": "Retry", "Пауза": "Pause", "Удалить загрузку": "Delete download",
        "Страница": "Page", "Файлы": "Files", "Загрузка удалена": "Download deleted", "Готово · %@": "Done · %@",
        "%@ из %@": "%@ of %@", "Пауза · %@": "Paused · %@", "%@ · %@/с": "%@ · %@/s", "В очереди · %@": "Queued · %@",
        "%@ · ещё не скачан": "%@ · not downloaded yet",
        // Поиск и медиатека
        "Недавние": "Recent", "Очистить": "Clear", "Популярно сейчас": "Popular now", "ИИ ищет по описанию…": "AI is searching by description…",
        "Первые %@ — найдены ИИ по описанию": "The first %@ were found by AI from your description",
        "Фильмы и сериалы": "Films and series", "Поиск по описанию не сработал. ": "Description search didn't work. ",
        "Отписаться": "Unfollow", "Подписаться": "Follow", "Дата рождения: %@": "Born: %@", "Смотреть позже": "Watch later",
        "Нравится": "Like", "История": "History", "Здесь пока пусто": "Nothing here yet",
        "Добавляйте фильмы кнопкой «+», а начатое появится в «Продолжить».": "Add films to Watch later; what you start will appear in Continue.",
        "Торренты": "Torrents", "Вселенные": "Universes", "Магнет-ссылка или адрес .torrent": "Magnet link or .torrent address",
        "Добавить торрент": "Add torrent", "Метаданные ещё не получены": "Metadata not received yet", "В TorrServer": "In TorrServer",
        "Здесь раздачи, которые уже открывались. Смахните влево, чтобы удалить.": "Torrents you have opened. Swipe left to delete.",
        "Не удалось": "Failed",
        "Самые известные работы каждого раздела — стеной постеров. Сведите пальцы, чтобы отдалить, разведите — чтобы рассмотреть; касание — карточка.":
            "The best-known works of each section as a wall of posters. Pinch to zoom out or in; tap for details.",
        "Стена не загрузилась": "The wall didn't load", "Проверьте сеть и откройте снова.": "Check your connection and open it again.",
        "Собираю вселенную…": "Building the universe…", "Открыть": "Open",
        // Компоненты и страница фильма
        "Обожаю": "Love", "Не моё": "Not for me", "Убрать из «Смотреть позже»": "Remove from Watch later",
        "Убрать из «Продолжить»": "Remove from Continue", "Оценка": "Rating", "Оценка %@": "Rating %@",
        "Продолжить просмотр": "Continue watching", "Открыть страницу": "Open page", "Духовные родственники": "Kindred spirits",
        "Близки по настроению и темам": "Close in mood and themes", "Проверяю, нет ли спойлеров…": "Checking for spoilers…",
        "ИИ подбирает фильмы по темам…": "AI is matching films by theme…", "Разбор сериала": "Series breakdown",
        "Разбор фильма": "Film breakdown", "Понятно": "OK",
        "Откроется, когда вы посмотрите хотя бы одну серию, — разбор будет до неё: в нём спойлеры.":
            "Unlocks once you've watched at least one episode — the breakdown goes up to it: it has spoilers.",
        "Откроется после просмотра фильма — в нём спойлеры.": "Unlocks after you watch the film — it has spoilers.",
        "ИИ разбирает сериал…": "AI is breaking down the series…", "ИИ разбирает фильм…": "AI is breaking down the film…",
        "ИИ не знает именно эту работу достаточно хорошо — разбора нет, чтобы не пересказывать другую.":
            "AI doesn't know this particular title well enough — no breakdown, so as not to retell a different one.",
        "Отзывы · %@": "Reviews · %@", "Порядок": "Order", "Сначала с высокой оценкой": "Highest rated first",
        "Сначала новые": "Newest first", "Сначала подробные": "Longest first", "ИИ читает отзывы…": "AI is reading the reviews…",
        "Перевожу…": "Translating…", "Отзыв": "Review", "Перевести": "Translate", "Оригинал": "Original",
        "Интересные факты": "Interesting facts", "Ещё": "More", "Загружаем интересные факты…": "Loading interesting facts…",
        "История создания пока недоступна в Википедии": "The production history isn't available on Wikipedia yet",
        "Википедия · %@": "Wikipedia · %@",
        "Другая раздача": "Another torrent", "Трейлер": "Trailer", "Мой список": "My list", "Похожие": "Similar", "Серии": "Episodes",
        "Отметить просмотренной": "Mark as watched", "Актёры и съёмочная группа": "Cast and crew", "Вы подписаны": "Following",
        "Сведения": "Details", "Описание скрыто, чтобы не было спойлеров": "Description hidden to avoid spoilers",
        "Биографии на TMDb нет.": "No biography on TMDb.", "Загружаем…": "Loading…", "Ещё от студии %@": "More from %@",
        // Главная
        "Вам понравится?": "Do you like it?", "Вышли в 4K": "Out in 4K", "Новое с вашими актёрами": "New with your actors",
        "Каталог не загрузился": "The catalogue didn't load", "Проверьте сеть и потяните вниз, чтобы повторить.": "Check your connection and pull down to retry.",
        "В сборке нет ключа TMDb.": "This build has no TMDb key.", "Скоро новые серии": "New episodes soon", "Сегодня": "Today",
        "Завтра": "Tomorrow", "Через %@ %@": "In %@ %@", "Потому что вам понравилось «%@»": "Because you liked “%@”",
        // Раздачи
        "По сидам": "By seeders", "По размеру": "By size", "По дате": "By date", "По названию": "By name", "По источнику": "By source",
        "Просмотренные": "Watched", "Все": "All", "Перевод": "Translation", "Любой": "Any", "Язык": "Language", "Сезон": "Season",
        "Год": "Year", "Трекер": "Tracker", "С субтитрами": "With subtitles", "Сбросить фильтры": "Reset filters", "Фильтры": "Filters",
        "Сортировка": "Sorting", "Ищу раздачи…": "Searching for torrents…", "Раздач не нашлось": "No torrents found",
        "Попробуйте другой сервер поиска в настройках.": "Try another search server in Settings.",
        "Не удалось открыть раздачу": "Couldn't open the torrent", "Загрузка": "Download",
        "%@ %@ · удерживайте, чтобы скачать": "%@ %@ · hold to download", "Скачать": "Download", "Скачать серию": "Download episode",
        "Скачать все серии раздачи": "Download all episodes", "Продолжить с %@": "Continue from %@",
        "В раздаче не нашёлся файл серии %@. Можно скачать все серии раздачи.": "No file for episode %@ in this torrent. You can download all its episodes.",
        "Загрузка началась — она в Медиатеке. Качается, пока приложение открыто.": "The download has started — it's in the Library.",
        "Озвучка": "Voice-over", "Как в раздаче": "As in the torrent", "Серия": "Episode", "Файл": "File",
        // Настройки
        "Поиск раздач": "Torrent search", "Плеер": "Player", "Вид": "Appearance", "Рекомендации": "Recommendations",
        "Каталог и оценки": "Catalogue and ratings", "ИИ": "AI", "Вместе": "Together", "Данные": "Data", "О приложении": "About",
        "Копия сохранена.": "Backup saved.", "Это не копия Aerial для iPhone.": "This isn't an Aerial for iPhone backup.",
        "Восстановлено %@ значений. Настройки применятся полностью после перезапуска Aerial.": "Restored %@ values. Settings fully apply after restarting Aerial.",
        "Свой адрес (JacRed или Jackett)": "Custom address (JacRed or Jackett)", "Ключ API (если нужен)": "API key (if needed)",
        "Torrentio — зарубежные раздачи": "Torrentio — international torrents",
        "Зелёная точка — сервер отвечает. Torrentio ищет по номеру IMDb, русских озвучек там мало.":
            "A green dot means the server responds. Torrentio searches by IMDb ID; few Russian voice-overs there.",
        "Состояние": "Status", "Кэш в памяти": "Memory cache", "%@ МБ": "%@ MB", "Адрес, например 192.168.1.10:8090": "Address, e.g. 192.168.1.10:8090",
        "Проверить": "Check",
        "Встроенный работает, пока открыто приложение или идёт фильм. Раздача качается во время просмотра — по мобильной сети это трафик.":
            "The built-in server runs while the app is open or a film plays. It downloads while you watch — on cellular that's data usage.",
        "TorrServer на телевизоре или компьютере в той же сети.": "TorrServer on a TV or computer on the same network.",
        "Описания серий": "Episode descriptions", "Скрывать спойлеры серий": "Hide episode spoilers",
        "Спойлеры: у непросмотренных серий кадр размыт, а описание скрыто.": "Spoilers: unwatched episodes have a blurred still and hidden description.",
        "Сбросить фильтры и сортировку раздач": "Reset torrent filters and sorting", "Очистить историю поиска": "Clear search history",
        "Следующая серия автоматически": "Play next episode automatically",
        "Серия кончилась — через 10 с начнётся следующая из той же раздачи. Заставку можно пропустить кнопкой, если её отметили зрители IntroDB или AniSkip. Скачанное (удерживайте раздачу — «Скачать») играет с телефона без сети и лежит в «Файлах» › Aerial › Downloads.":
            "When an episode ends, the next one from the same torrent starts in 10 s. The intro can be skipped if IntroDB or AniSkip viewers marked it. Downloads (hold a torrent — Download) play offline and are in Files › Aerial › Downloads.",
        "Размер постеров": "Poster size", "Обычные": "Normal", "Крупные": "Large", "Размер фото актёров": "Actor photo size",
        "Логотипы названий": "Title logos",
        "Логотипы — название фильма надписью из TMDb вместо текста. Размеры применяются к открытым заново экранам.":
            "Logos show the film's title artwork from TMDb instead of text. Sizes apply to screens opened afterwards.",
        "Учитывать историю просмотра": "Use watch history", "Оценок": "Ratings", "Очистить «Продолжить»": "Clear Continue",
        "Очистить историю просмотра": "Clear watch history", "Начать рекомендации с нуля": "Start recommendations over",
        "Сбросить оценки": "Reset ratings",
        "«Вам понравится?» подбирается по оценкам «Нравится», «Обожаю» и «Не моё», «Моему списку» и просмотренному — вместе с похожими по TMDb.":
            "“Do you like it?” is built from your Like, Love and Not for me ratings, Watch later and history — plus similar titles from TMDb.",
        "Прокси TMDb": "TMDb proxy", "Ключ MDBList (оценки IMDb, RT)": "MDBList key (IMDb, RT ratings)", "Кэш ответов": "Response cache",
        "Очистить кэш": "Clear cache", "Каталог": "Catalogue",
        "Если TMDb недоступен напрямую, запросы идут через этот Worker. Бесплатный ключ MDBList — на mdblist.com, в разделе Preferences: с ним на странице фильма видны оценки IMDb, Rotten Tomatoes и Metacritic.":
            "If TMDb isn't reachable directly, requests go through this Worker. A free MDBList key is at mdblist.com › Preferences: with it, film pages show IMDb, Rotten Tomatoes and Metacritic ratings.",
        "Показывать оценки MDBList": "Show MDBList ratings", "Оценки": "Ratings",
        "TMDb всегда первым: оценка пользователей кинобазы из 10.": "TMDb is always first: the database users' rating out of 10.",
        "ИИ включён": "AI on", "Ключ Gemini (aistudio.google.com)": "Gemini key (aistudio.google.com)", "Ключ Groq (console.groq.com)": "Groq key (console.groq.com)",
        "Подборки по настроению на главной": "Mood collections on Home", "Сводка отзывов": "Review summary", "Переводить отзывы сразу": "Translate reviews right away",
        "Google и Groq не обслуживают вашу страну — ИИ работает только через VPN.": "Google and Groq don't serve your country — AI works only via VPN.",
        "Свои бесплатные ключи. ИИ ищет фильм по описанию своими словами, подбирает «Вам понравится?» и подборки по настроению, находит «Духовных родственников», делает «Разбор» после просмотра, сводит и переводит отзывы. Есть оба ключа — основной Gemini, Groq подхватывает при лимите.":
            "Your own free keys. AI finds a film from your own description, builds “Do you like it?” and mood collections, finds kindred spirits, writes a breakdown after watching, and summarises and translates reviews. With both keys Gemini is primary and Groq takes over at the limit.",
        "Ключ OpenSubtitles": "OpenSubtitles key", "Языки субтитров, например ru,en": "Subtitle languages, e.g. en,ru",
        "С ключом (бесплатно: opensubtitles.com/consumers) в плеере появляется «Субтитры › Найти субтитры…». Без ключа — только субтитры из самой раздачи.":
            "With a key (free: opensubtitles.com/consumers) the player gets Subtitles › Find subtitles…. Without one, only the torrent's own subtitles.",
        "Друзья и комнаты": "Friends and rooms",
        "Друзья видят, что вы смотрите, и могут войти в вашу комнату: пауза и перемотка — у всех сразу.":
            "Friends see what you're watching and can join your room: pause and seeking happen for everyone.",
        "Сохранить копию…": "Save backup…", "Восстановить из копии…": "Restore from backup…",
        "Настройки, ключи, «Мой список», оценки, прогресс, подписки и друзья — одним файлом. Его можно сохранить в «Файлы» или iCloud и восстановить на другом iPhone.":
            "Settings, keys, My list, ratings, progress, follows and friends in one file. Save it to Files or iCloud and restore it on another iPhone.",
        "Версия": "Version", "Журналы": "Logs", "Файлы › На iPhone › Aerial › logs": "Files › On My iPhone › Aerial › logs",
        "Поделиться журналами": "Share logs", "Остановлен": "Stopped", "Запускается…": "Starting…", "Работает · %@": "Running · %@",
        "Ошибка: %@": "Error: %@", "Проверяю…": "Checking…", "Некорректный адрес": "Invalid address", "Не отвечает": "Not responding",
        "Язык приложения": "App language", "Как в системе": "System", "Перезапустите Aerial": "Restart Aerial",
        "Язык сменится после перезапуска: закройте Aerial в переключателе приложений и откройте снова.":
            "The language changes after a restart: close Aerial in the app switcher and open it again.",
        "Каталог, даты и ответы ИИ — тоже на этом языке.": "The catalogue, dates and AI answers use this language too.",
    ]
}
