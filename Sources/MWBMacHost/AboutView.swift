// Finestra "Informazioni su": icona, versione e build dal bundle, licenza e avvertenza.

import AppKit
import SwiftUI

struct AboutView: View {
    static let projectURL = URL(string: "https://github.com/fcelsa/mwbmac")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(verbatim: "MWB Mac Host")
                .font(.title2.bold())
            Text(L("Version %@ (build %@)", version, build))
                .font(.callout)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            Text(L("Use the Mac's keyboard and mouse on a Windows PC with PowerToys Mouse Without Borders."))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            Link(L("Project page"), destination: AboutView.projectURL)
            Divider().padding(.vertical, 4)
            Text(L("MIT License. Not affiliated with Microsoft. PowerToys and Mouse Without Borders are trademarks of Microsoft Corporation."))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 360)
    }
}
