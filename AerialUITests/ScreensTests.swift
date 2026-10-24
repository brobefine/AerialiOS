import XCTest

/// Снимки экранов на CI (Mac нет — так видно, что собралось и как выглядит): главная, разделы, сериал с сезонами
/// и раздачами серии, фильм, актёр, «Смотреть всё», медиатека, настройки, поиск; отдельно — воспроизведение.
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

    private func back(_ times: Int = 1) {
        for _ in 0..<times {
            let button = app.navigationBars.buttons.element(boundBy: 0)
            if button.waitForExistence(timeout: 2), button.isHittable { button.tap() }
        }
    }

    func testScreens() {
        app.launchArguments = ["-uiTest"]
        app.launch()

        XCTAssertTrue(element("poster").waitForExistence(timeout: 60), "каталог не загрузился")
        shot("01-home", settle: 3)
        app.swipeUp()
        shot("02-home-rows")
        app.swipeDown()
        app.swipeDown()

        // Сериал: раздел, страница, сезоны и серии, раздачи серии.
        if tap(element("shelf-series")) {
            shot("03-shelf-series", settle: 3)
            if tap(element("poster")) {
                _ = element("details-watch").waitForExistence(timeout: 30)
                shot("04-series-details")
                app.swipeUp()
                if element("episode").waitForExistence(timeout: 10) { shot("05-series-episodes") }
                if tap(element("episode"), wait: 2) {
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

        // Фильм: страница, актёр, раздачи.
        if tap(element("poster")) {
            let watch = element("details-watch")
            XCTAssertTrue(watch.waitForExistence(timeout: 30), "страница фильма не открылась")
            shot("07-details")
            app.swipeUp()
            shot("08-details-more")
            if tap(element("person"), wait: 3) {
                shot("09-person", settle: 3)
                back()
            }
            app.swipeDown()
            app.swipeDown()
            if tap(watch) {
                _ = element("release").waitForExistence(timeout: 60)
                shot("10-releases", settle: 1)
                back()
            }
            back()
        }

        // «Смотреть всё» первого ряда.
        if tap(element("section-header")) {
            shot("11-section", settle: 3)
            back()
        }

        // Поиск — последним: на iOS 26 поле поиска с клавиатурой закрывает панель вкладок.
        if tap(app.buttons["Медиатека"].firstMatch, wait: 5) {
            shot("12-library", settle: 1)
        }
        if tap(app.buttons["Главная"].firstMatch, wait: 5), tap(element("settings")) {
            shot("13-settings", settle: 4)
            tap(app.buttons["Готово"].firstMatch, wait: 3)
        }
        if tap(app.buttons["Поиск"].firstMatch, wait: 5) {
            shot("14-search-empty")
            let field = app.searchFields.firstMatch
            if tap(field, wait: 5) {
                field.typeText("Дюна")
                if element("poster").waitForExistence(timeout: 10) { shot("15-search", settle: 3) }
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
        if tap(app.buttons["Закрыть"].firstMatch, wait: 3) {
            shot("23-after-player", settle: 3)
        }
    }
}
