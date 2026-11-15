import SwiftUI

@main
struct JugeDeLigneApp: App {
    @StateObject private var journal: Journal
    @StateObject private var moteur: Moteur
    @StateObject private var rejeu: Rejeu

    init() {
        let j = Journal()
        _journal = StateObject(wrappedValue: j)
        _moteur = StateObject(wrappedValue: Moteur(journal: j))
        _rejeu = StateObject(wrappedValue: Rejeu(journal: j))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                VueDirect(moteur: moteur)
                    .tabItem { Label("Direct", systemImage: "camera.viewfinder") }
                VueRejeu(rejeu: rejeu)
                    .tabItem { Label("Rejeu", systemImage: "film.stack") }
                VueJournal(journal: journal)
                    .tabItem { Label("Journal", systemImage: "list.bullet.rectangle") }
            }
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
