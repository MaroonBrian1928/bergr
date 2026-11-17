// The site's widget pictures (scripts/site-widgets.sh): the REAL widget and Live Activity views from
// BergrLiveActivity/, compiled together with this file, drawn with ImageRenderer at @3x onto Home
// Screen / Lock Screen-style backdrops. The data is SiteWidgetFixture.swift (the demo's agents).
// Writes <out>/{home-widgets,lock-live-activity,usage-widget}-{light,dark}.png.
import SwiftUI
import WidgetKit
import UIKit

nonisolated(unsafe) let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "out")

struct Wallpaper: View {
    let dark: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: dark
                ? [Color(red: 0.10, green: 0.11, blue: 0.16), Color(red: 0.20, green: 0.13, blue: 0.10)]
                : [Color(red: 0.98, green: 0.86, blue: 0.72), Color(red: 0.74, green: 0.82, blue: 0.95)],
                startPoint: .top, endPoint: .bottom)
            Circle().fill(dark ? Color(red: 0.55, green: 0.33, blue: 0.12) : Color(red: 1.0, green: 0.70, blue: 0.40))
                .frame(width: 420).offset(x: -150, y: -260).opacity(dark ? 0.55 : 0.7)
            Circle().fill(dark ? Color(red: 0.16, green: 0.26, blue: 0.48) : Color(red: 0.55, green: 0.70, blue: 1.0))
                .frame(width: 460).offset(x: 170, y: 300).opacity(dark ? 0.6 : 0.6)
            Circle().fill(dark ? Color(red: 0.36, green: 0.20, blue: 0.30) : Color(red: 0.98, green: 0.62, blue: 0.70))
                .frame(width: 300).offset(x: 160, y: -120).opacity(0.45)
        }
        // The circles are wider than the screen: take the offered size, or the status bar's right
        // end (the battery) gets pushed out of the picture.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blur(radius: 70)
        .clipped()
    }
}

struct WidgetBox<Content: View>: View {
    let width: CGFloat, height: CGFloat
    let dark: Bool
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(16)
            .frame(width: width, height: height)
            .background(dark ? Color(white: 0.13) : Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .tint(dark ? Color.white : Color.black)
            .environment(\.colorScheme, dark ? .dark : .light)
            .shadow(color: .black.opacity(dark ? 0.3 : 0.08), radius: 10, y: 4)
    }
}

/// A full battery, drawn: ImageRenderer cuts off the right end of the battery SF Symbols.
struct Battery: View {
    var body: some View {
        HStack(spacing: 1.5) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .frame(width: 25, height: 12)
            RoundedRectangle(cornerRadius: 1).frame(width: 1.5, height: 4).opacity(0.5)
        }
    }
}

struct StatusBar: View {
    let lock: Bool
    var body: some View {
        HStack {
            if lock { Spacer().frame(width: 30) } else { Text("9:41").font(.system(size: 17, weight: .semibold)).frame(width: 90) }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "cellularbars"); Image(systemName: "wifi"); Battery()
            }
            .font(.system(size: 15, weight: .semibold))
            .fixedSize()
            .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        // Exactly the screen's width: unpinned, the row came out wider than the picture and lost
        // the battery's right end.
        .frame(width: screen.width, height: 54)
    }
}

let screen = CGSize(width: 402, height: 874)

struct HomeScreen: View {
    let dark: Bool
    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper(dark: dark)
            VStack(spacing: 22) {
                StatusBar(lock: false).foregroundStyle(dark ? .white : .black)
                WidgetBox(width: 364, height: 170, dark: dark) {
                    AgentsWidgetView(snapshot: SiteWidgetFixture.agents, family: .systemMedium)
                }
                HStack(spacing: 24) {
                    WidgetBox(width: 170, height: 170, dark: dark) { AgentsWidgetView(snapshot: SiteWidgetFixture.agents, family: .systemSmall) }
                    WidgetBox(width: 170, height: 170, dark: dark) { UsageWidgetView(snapshot: SiteWidgetFixture.usage, family: .systemSmall) }
                }
                Spacer()
                HStack(spacing: 8) {
                    ForEach(0..<3) { i in Circle().fill(.white.opacity(i == 0 ? 0.95 : 0.45)).frame(width: 7) }
                }
                .padding(.bottom, 130)
            }
            VStack { Spacer(); Capsule().fill((dark ? Color.white : Color.black).opacity(0.85)).frame(width: 140, height: 5).padding(.bottom, 9) }
        }
        .frame(width: screen.width, height: screen.height)
    }
}

struct LockScreen: View {
    let dark: Bool
    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper(dark: dark)
            VStack(spacing: 0) {
                StatusBar(lock: true)
                Image(systemName: "lock.fill").font(.system(size: 18, weight: .semibold)).padding(.top, 2)
                Text("Monday, November 16").font(.system(size: 21, weight: .semibold)).padding(.top, 10)
                Text("9:41").font(.system(size: 104, weight: .bold, design: .rounded)).padding(.top, -8)
                Spacer()
                LockScreenView(state: SiteWidgetFixture.liveActivity)
                    .frame(width: 364)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .environment(\.colorScheme, .dark)
                Spacer().frame(height: 40)
                HStack {
                    Circle().fill(.black.opacity(0.25)).frame(width: 50).overlay(Image(systemName: "flashlight.off.fill"))
                    Spacer()
                    Circle().fill(.black.opacity(0.25)).frame(width: 50).overlay(Image(systemName: "camera.fill"))
                }
                .font(.system(size: 20))
                .padding(.horizontal, 46)
                Capsule().fill(.white.opacity(0.9)).frame(width: 140, height: 5).padding(.top, 26).padding(.bottom, 9)
            }
            .foregroundStyle(.white)
        }
        .frame(width: screen.width, height: screen.height)
    }
}

struct UsageTile: View {
    let dark: Bool
    var body: some View {
        ZStack {
            Wallpaper(dark: dark)
            WidgetBox(width: 170, height: 170, dark: dark) { UsageWidgetView(snapshot: SiteWidgetFixture.usage, family: .systemSmall) }
        }
        .frame(width: 230, height: 230)
    }
}

@MainActor func save(_ view: some View, _ name: String, dark: Bool) {
    let r = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
    r.scale = 3
    guard let image = r.uiImage, let data = image.pngData() else { print("failed \(name)"); return }
    try! data.write(to: out.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    print("wrote \(name) \(image.size)")
}

@main struct SiteWidgetsRender { @MainActor static func main() {
    for dark in [false, true] {
        save(HomeScreen(dark: dark), "home-widgets", dark: dark)
        save(LockScreen(dark: dark), "lock-live-activity", dark: dark)
        save(UsageTile(dark: dark), "usage-widget", dark: dark)
    }
}
}
