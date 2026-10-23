import XCTest

/// Снимки экранов на CI (Mac нет — так видно, что собралось): каталог, страница фильма, раздачи, поиск, медиатека,
/// настройки. Снимки — в `SCREENS_DIR` (CI передаёт через `TEST_RUNNER_SCREENS_DIR`) и вложениями результата.
final class ScreensTests: XCTestCase {
    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCREENS_DIR"] ?? NSTemporaryDirectory())
    }

    override func setUp() {
        continueAfterFailure = true
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest"]
        app.launch()

        let poster = element(app, "poster")
        XCTAssertTrue(poster.waitForExistence(timeout: 90), "каталог не загрузился")
        sleep(5)
        shot("01-home")
        app.swipeUp()
        sleep(3)
        shot("02-home-rows")
        app.swipeDown()
        app.swipeDown()
        sleep(1)

        element(app, "poster").tap()
        let watch = element(app, "details-watch")
        XCTAssertTrue(watch.waitForExistence(timeout: 40), "страница фильма не открылась")
        sleep(4)
        shot("03-details")
        app.swipeUp()
        sleep(2)
        shot("04-details-more")
        app.swipeDown()
        app.swipeDown()
        sleep(1)

        if watch.isHittable {
            watch.tap()
            _ = element(app, "release").waitForExistence(timeout: 90)
            sleep(2)
            shot("05-releases")
        }

        // Поиск — последним: на iOS 26 поле поиска с клавиатурой закрывает панель вкладок.
        let library = app.buttons["Медиатека"].firstMatch
        if library.waitForExistence(timeout: 5) {
            library.tap()
            sleep(2)
            shot("06-library")
        }

        let home = app.buttons["Главная"].firstMatch
        if home.waitForExistence(timeout: 5) {
            home.tap()
            let settings = element(app, "settings")
            if settings.waitForExistence(timeout: 10) {
                settings.tap()
                sleep(6)
                shot("07-settings")
                let done = app.buttons["Готово"].firstMatch
                if done.waitForExistence(timeout: 3) { done.tap() }
                sleep(1)
            }
        }

        let search = app.buttons["Поиск"].firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            sleep(3)
            shot("08-search-empty")
            let field = app.searchFields.firstMatch
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText("Дюна")
                sleep(5)
                shot("09-search")
            }
        }
    }

    /// Встроенный TorrServer и mpv на свободном фильме (Big Buck Bunny, CC BY): раздача → подкачка → кадр.
    func testPlaybackSmoke() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-smokeLink", "https://webtorrent.io/torrents/big-buck-bunny.torrent"]
        app.launch()
        sleep(20)
        shot("10-player-preparing")
        sleep(70)
        shot("11-player")
        app.tap()
        sleep(1)
        shot("12-player-controls")
        // Закрытие плеера — обратно в книжную ориентацию.
        let close = app.buttons["Закрыть"].firstMatch
        if close.waitForExistence(timeout: 3) {
            close.tap()
            sleep(3)
            shot("13-after-player")
        }
    }
}
