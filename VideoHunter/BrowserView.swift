//
//  BrowserView.swift
//  VideoHunter
//

import SwiftUI
import WebKit

struct BrowserView: UIViewRepresentable {
    @ObservedObject var controller: BrowserController

    func makeUIView(context: Context) -> WKWebView {
        controller.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
