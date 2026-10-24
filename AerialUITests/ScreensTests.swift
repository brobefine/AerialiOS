import XCTest

/// Снимки экранов на CI (Mac нет — так видно, что собралось и как выглядит): главная, разделы, сериал с сезонами
/// и раздачами серии, фильм и его оценка, «Вам понравится?», актёр, «Смотреть всё», медиатека, настройки, поиск;
/// отдельно — воспроизведение.
/// Ждём появления элементов, а не фиксированное время; короткая пауза перед снимком — чтобы догрузились картинки.
/// Шаг, для которого не нашлось элемента, пропускается (снимка нет), а не роняет весь прогон.
/// Снимки — в `SCREENS_DIR` (CI передаёт через `TEST_RUNNER_SCREENS_DIR`) и вложениями результата.
final class ScreensTests: XCTestCase {
    private var app: XCUIApplication!

    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCREENS_DIR"] ?? NSTemporaryDirectory())
    }

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    /// Снимок после короткой паузы — догружаются картинки.
    private func shot(_ name: String, settle: UInt32 = 2) {
        sleep(settle)
        let screenshot = XCUIScreen.main.screenshot()
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Нажать, если элемент появился и до него можно дотянуться; иначе шаг пропускается.
    @discardableResult
    private func tap(_ element: XCUIElement, wait: TimeInterval = 10) -> Bool {
        guard element.waitForExistence(timeout: wait), element.isHittable else { return false }
        element.tap()
        return true
    }

    /// Первый элемент, до которого можно дотянуться: у страничных TabView соседние страницы тоже в дереве.
    private func visible(_ identifier: String, wait: TimeInterval = 10) -> XCUIElement? {
        let query = app.descendants(matching: .any).matching(identifier: identifier)
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            if let hit = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return hit }
            usleep(300_000)
        } while Date() < deadline
        return nil
    }

    @discardableResult
    private func tapVisible(_ identifier: String, wait: TimeInterval = 10) -> Bool {
        guard let element = visible(identifier, wait: wait) else { return false }
        element.tap()
        return true
    }

    private func back(_ times: Int = 1) {
        for _ in 0..<times {
            let button = app.navigationBars.buttons.element(boundBy: 0)
            if button.waitForExistence(timeout: 2), button.isHittable { button.tap() }
        }
    }

    /// iPhone: все экраны.
    func testScreens() {
        home()
        series()
        movie(person: true)
        forYou()
        section()
        tabs(search: true)
    }

    /// iPad: ключевые экраны — главная, фильм, раздачи, настройки.
    func testTabletScreens() {
        home()
        movie(person: false)
        tabs(search: false)
    }

    private func home() {
        app.launchArguments = ["-uiTest"]
        app.launch()
        XCTAssertNotNil(visible("poster", wait: 60), "каталог не загрузился")
        shot("01-home", settle: 3)
        app.swipeUp()
        shot("02-home-rows")
        app.swipeDown()
        app.swipeDown()
        // Свайп по заголовку ряда — следующий раздел, затем обратно.
        if let header = visible("section-header", wait: 5) {
            header.swipeLeft()
            shot("02b-home-swipe")
            visible("section-header", wait: 5)?.swipeRight()
        }
    }

    /// Сериал: раздел, страница, сезоны и серии, раздачи серии.
    private func series() {
        if tap(element("shelf-series")) {
            shot("03-shelf-series", settle: 3)
            if tapVisible("poster") {
                _ = element("details-watch").waitForExistence(timeout: 30)
                shot("04-series-details")
                app.swipeUp()
                if visible("episode") != nil { shot("05-series-episodes") }
                if tapVisible("episode", wait: 2) {
                    _ = element("release").waitForExistence(timeout: 60)
                    shot("06-episode-releases", settle: 1)
                    back()
                }
                back()
            }
            app.swipeDown()
            app.swipeDown()
            tap(element("shelf-all"))
        }
    }

    /// Фильм: страница, актёр, раздачи.
    private func movie(person: Bool) {
        if tapVisible("poster") {
            let watch = element("details-watch")
            XCTAssertTrue(watch.waitForExistence(timeout: 30), "страница фильма не открылась")
            shot("07-details")
            // Оценка «Нравится» — из неё главная собирает «Вам понравится?».
            if tap(element("details-rate"), wait: 3), tap(app.buttons["Нравится"].firstMatch, wait: 3) {
                shot("07b-details-rated", settle: 1)
            }
            app.swipeUp()
            shot("08-details-more")
            if person, tapVisible("person", wait: 3) {
                shot("09-person", settle: 3)
                back()
            }
            app.swipeDown()
            app.swipeDown()
            if tap(watch) {
                _ = element("release").waitForExistence(timeout: 60)
                shot("10-releases", settle: 1)
                app.swipeLeft()
                shot("10b-releases-filter", settle: 1)
                back()
            }
            back()
        }
    }

    /// Ряд «Вам понравится?» после оценки фильма: соседи TMDb приходят за несколько секунд.
    private func forYou() {
        if app.staticTexts["Вам понравится?"].firstMatch.waitForExistence(timeout: 20) {
            shot("07c-home-for-you", settle: 2)
        }
    }

    /// «Смотреть всё» первого ряда.
    private func section() {
        if tapVisible("section-header") {
            shot("11-section", settle: 3)
            back()
        }
    }

    /// Медиатека, настройки и поиск — последним: на iOS 26 поле поиска с клавиатурой закрывает панель вкладок.
    private func tabs(search: Bool) {
        if tap(app.buttons["Медиатека"].firstMatch, wait: 5) {
            shot("12-library", settle: 1)
            // «Вселенные»: шары разделов, затем стена фильмов.
            if tap(app.buttons["Вселенные"].firstMatch, wait: 3) {
                shot("12b-universes", settle: 4)
                if tap(app.staticTexts["Фильмы"].firstMatch, wait: 3) {
                    shot("12c-wall", settle: 8)
                    back()
                }
                back()
            }
        }
        if tap(app.buttons["Настройки"].firstMatch, wait: 5) {
            shot("13-settings", settle: 4)
            if tap(app.staticTexts["Поиск раздач"].firstMatch, wait: 3) {
                shot("13b-settings-parser", settle: 2)
                back()
            }
        }
        if search, tap(app.buttons["Поиск"].firstMatch, wait: 5) {
            shot("14-search-empty")
            let field = app.searchFields.firstMatch
            if tap(field, wait: 5) {
                field.typeText("Дюна")
                if visible("poster") != nil { shot("15-search", settle: 3) }
            }
        }
    }

    /// Встроенный TorrServer и mpv на свободном фильме (Big Buck Bunny, CC BY): раздача → подкачка → кадр;
    /// плеер в альбомной ориентации, по закрытии — снова книжная. Ждём, пока часы плеера уйдут с 0:00.
    func testPlaybackSmoke() {
        app.launchArguments = ["-uiTest", "-smokeLink", "https://webtorrent.io/torrents/big-buck-bunny.torrent"]
        app.launch()
        shot("20-player-preparing", settle: 8)
        let time = element("player-time")
        let deadline = Date().addingTimeInterval(120)
        var playing = false
        while Date() < deadline {
            if time.exists, !time.label.isEmpty, time.label != "0:00", time.label != "0:01" {
                playing = true
                break
            }
            sleep(2)
        }
        XCTAssertTrue(playing, "видео не пошло за 2 минуты")
        shot("21-player", settle: 3)
        XCTAssertTrue(tap(app.buttons["player-close"].firstMatch, wait: 3), "нет кнопки закрытия плеера")
        XCTAssertTrue(time.waitForNonExistence(timeout: 10), "плеер не закрылся")
        shot("23-after-player", settle: 3)
    }
}
