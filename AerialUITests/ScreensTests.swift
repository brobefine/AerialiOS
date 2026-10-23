import XCTest

/// Снимки экранов на CI (Mac нет — так видно, что собралось и как выглядит): главная, разделы, сериал с сезонами
/// и раздачами серии, фильм, актёр, «Смотреть всё», медиатека, настройки, поиск; отдельно — воспроизведение.
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

    private func shot(_ name: String) {
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
            if button.exists && button.isHittable {
                button.tap()
                sleep(2)
            }
        }
    }

    func testScreens() {
        app.launchArguments = ["-uiTest"]
        app.launch()

        XCTAssertTrue(element("poster").waitForExistence(timeout: 90), "каталог не загрузился")
        sleep(5)
        shot("01-home")
        app.swipeUp()
        sleep(3)
        shot("02-home-rows")
        app.swipeDown()
        app.swipeDown()

        // Сериал: раздел, страница, сезоны и серии, раздачи серии.
        if tap(element("shelf-series")) {
            sleep(6)
            shot("03-shelf-series")
            if tap(element("poster")) {
                _ = element("details-watch").waitForExistence(timeout: 40)
                sleep(4)
                shot("04-series-details")
                app.swipeUp()
                sleep(3)
                shot("05-series-episodes")
                if tap(element("episode")) {
                    _ = element("release").waitForExistence(timeout: 90)
                    sleep(2)
                    shot("06-episode-releases")
                    back()
                }
                back()
            }
            app.swipeDown()
            app.swipeDown()
            tap(element("shelf-all"))
            sleep(5)
        }

        // Фильм: страница, актёр, раздачи.
        if tap(element("poster")) {
            let watch = element("details-watch")
            XCTAssertTrue(watch.waitForExistence(timeout: 40), "страница фильма не открылась")
            sleep(4)
            shot("07-details")
            app.swipeUp()
            sleep(2)
            shot("08-details-more")
            if tap(element("person"), wait: 5) {
                sleep(5)
                shot("09-person")
                back()
            }
            app.swipeDown()
            app.swipeDown()
            if tap(watch) {
                _ = element("release").waitForExistence(timeout: 90)
                sleep(2)
                shot("10-releases")
                back()
            }
            back()
        }

        // «Смотреть всё» первого ряда.
        if tap(element("section-header")) {
            sleep(6)
            shot("11-section")
            back()
        }

        // Поиск — последним: на iOS 26 поле поиска с клавиатурой закрывает панель вкладок.
        if tap(app.buttons["Медиатека"].firstMatch, wait: 5) {
            sleep(2)
            shot("12-library")
        }
        if tap(app.buttons["Главная"].firstMatch, wait: 5), tap(element("settings")) {
            sleep(6)
            shot("13-settings")
            tap(app.buttons["Готово"].firstMatch, wait: 3)
            sleep(1)
        }
        if tap(app.buttons["Поиск"].firstMatch, wait: 5) {
            sleep(3)
            shot("14-search-empty")
            let field = app.searchFields.firstMatch
            if tap(field, wait: 5) {
                field.typeText("Дюна")
                sleep(5)
                shot("15-search")
            }
        }
    }

    /// Встроенный TorrServer и mpv на свободном фильме (Big Buck Bunny, CC BY): раздача → подкачка → кадр;
    /// плеер в альбомной ориентации, по закрытии — снова книжная.
    func testPlaybackSmoke() {
        app.launchArguments = ["-uiTest", "-smokeLink", "https://webtorrent.io/torrents/big-buck-bunny.torrent"]
        app.launch()
        sleep(20)
        shot("20-player-preparing")
        sleep(70)
        shot("21-player")
        app.tap()
        sleep(1)
        shot("22-player-controls")
        if tap(app.buttons["Закрыть"].firstMatch, wait: 3) {
            sleep(4)
            shot("23-after-player")
        }
    }
}
