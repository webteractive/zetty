// swiftlint:disable:this file_name
// swiftlint:disable all
// swift-format-ignore-file
// swiftformat:disable all
// Generated using tuist — https://github.com/tuist/tuist

#if os(macOS)
  import AppKit.NSFont
#elseif os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
  import UIKit.UIFont
#endif
#if canImport(SwiftUI)
  import SwiftUI
#endif

// swiftlint:disable superfluous_disable_command
// swiftlint:disable file_length

// MARK: - Fonts

// swiftlint:disable identifier_name line_length type_body_length
public enum ZettyFontFamily: Sendable {
  public enum IBMPlexMono: Sendable {
    public static let bold = ZettyFontConvertible(name: "IBMPlexMono-Bold", family: "IBM Plex Mono", path: "IBMPlexMono-Bold.ttf")
    public static let all: [ZettyFontConvertible] = [bold]
  }
  public enum JetBrainsMono: Sendable {
    public static let bold = ZettyFontConvertible(name: "JetBrainsMono-Bold", family: "JetBrains Mono", path: "JetBrainsMono-Bold.ttf")
    public static let medium = ZettyFontConvertible(name: "JetBrainsMono-Medium", family: "JetBrains Mono", path: "JetBrainsMono-Medium.ttf")
    public static let regular = ZettyFontConvertible(name: "JetBrainsMono-Regular", family: "JetBrains Mono", path: "JetBrainsMono-Regular.ttf")
    public static let semiBold = ZettyFontConvertible(name: "JetBrainsMono-SemiBold", family: "JetBrains Mono", path: "JetBrainsMono-SemiBold.ttf")
    public static let all: [ZettyFontConvertible] = [bold, medium, regular, semiBold]
  }
  public static let allCustomFonts: [ZettyFontConvertible] = [IBMPlexMono.all, JetBrainsMono.all].flatMap { $0 }
  public static func registerAllCustomFonts() {
    allCustomFonts.forEach { $0.register() }
  }
}
// swiftlint:enable identifier_name line_length type_body_length

// MARK: - Implementation Details

public struct ZettyFontConvertible: Sendable {
  public let name: String
  public let family: String
  public let path: String

  #if os(macOS)
  public typealias Font = NSFont
  #elseif os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
  public typealias Font = UIFont
  #endif

  public func font(size: CGFloat) -> Font {
    guard let font = Font(font: self, size: size) else {
      fatalError("Unable to initialize font '\(name)' (\(family))")
    }
    return font
  }

  #if canImport(SwiftUI)
  @available(iOS 13.0, tvOS 13.0, watchOS 6.0, macOS 10.15, *)
  public func swiftUIFont(size: CGFloat) -> SwiftUI.Font {
    guard let font = Font(font: self, size: size) else {
      fatalError("Unable to initialize font '\(name)' (\(family))")
    }
    #if os(macOS)
    return SwiftUI.Font.custom(font.fontName, size: font.pointSize)
    #elseif os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    return SwiftUI.Font(font)
    #endif
  }
  #endif

  public func register() {
    // swiftlint:disable:next conditional_returns_on_newline
    guard let url = url else { return }
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
  }

  fileprivate var url: URL? {
    // swiftlint:disable:next implicit_return
    return Bundle.module.url(forResource: path, withExtension: nil)
  }
}

public extension ZettyFontConvertible.Font {
  convenience init?(font: ZettyFontConvertible, size: CGFloat) {
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    if !UIFont.fontNames(forFamilyName: font.family).contains(font.name) {
      font.register()
    }
    #elseif os(macOS)
    if let url = font.url, CTFontManagerGetScopeForURL(url as CFURL) == .none {
      font.register()
    }
    #endif

    self.init(name: font.name, size: size)
  }
}
// swiftformat:enable all
// swiftlint:enable all
