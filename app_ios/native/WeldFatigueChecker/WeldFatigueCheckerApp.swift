// WeldFatigueCheckerApp.swift
import SwiftUI

@main
struct WeldFatigueCheckerApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
        }
    }
}
