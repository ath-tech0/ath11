import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var licenseManager: LicenseManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: Tab = .normal
    @State private var normal = [false, false, false]
    @State private var max = [false, false, false]
    @StateObject private var patchStore = PatchProjectStore()
    @State private var patchOperationBusy = false
    @State private var patchMessage = "READY — SELECT A PATCH"

    enum Tab: String, CaseIterable {
        case normal = "FF Normal"
        case max = "FF Max"
        case developer = "Developer"
    }

    // Display names
    let normalNames = ["AIMBODY", "AIM DRAG", "AIM DRAG + ANTENA"]
    let maxNames = ["AIMBODY", "AIM DRAG", "AIM DRAG + ANTENA"]

    // Package mapping is intentionally unique per tab/button. A package must
    // never be shared by FF NORMAL and FF MAX because its transaction receipt
    // belongs to the package project and would make the two UI toggles mirror
    // one another.
    // FF NORMAL:
    // AIMBODY  → BODYFF.3105
    // AIM DRAG → DRAGFF.3105
    // AIM DRAG + ANTENA → DRAGANTENAFF.3105
    // FF MAX uses separate package files below.
    private let normalPackages = [
        "BODYFF.3105",
        "DRAGFF.3105",
        "DRAGANTENAFF.3105"
    ]
    private let maxPackages = [
        "BODYFFM.3105",
        "DRAGFFM.3105",
        "DRAGANTENAFFM.3105"
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AnimatedHyperBackdrop().ignoresSafeArea()
                VStack(spacing: 0) {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 16) {
                            header
                            if tab == .developer {
                                developer
                            } else {
                                controls
                            }
                        }
                        .frame(minHeight: proxy.size.height - 8, alignment: .top)
                        .padding(.horizontal, 18)
                        .padding(.top, 18)
                        .padding(.bottom, 18)
                    }
                    tabs
                        .padding(.horizontal, 22)
                        .padding(.bottom, 14)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .preferredColorScheme(.dark)
        .sheet(item: $patchStore.passwordRequest, onDismiss: patchStore.cancelUnlock) { _ in
            PatchUnlockPrompt(store: patchStore)
        }
        .onAppear {
            patchStore.reload()
            syncPatchStates()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, !patchOperationBusy else { return }
            syncPatchStates()
            patchMessage = "READY — SELECT A PATCH"
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(tab == .developer ? "ATH REGEDIT" : "ATH EXTERNAL")
                    .font(.system(size: 25, weight: .black, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.white)
                Text("PATCH CONTROL CENTER")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.7)
                    .foregroundStyle(AppTheme.accent)
            }
            Spacer()
            logo
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [.white.opacity(0.14), AppTheme.accent.opacity(0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24)
        )
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(AppTheme.accent.opacity(0.35)))
    }

    private var logo: some View {
        Image("ATHExternalLogo")
            .resizable()
            .scaledToFill()
            .frame(width: 58, height: 58)
            .clipShape(Circle())
            .overlay(Circle().stroke(AppTheme.accent.opacity(0.8), lineWidth: 2))
            .shadow(color: AppTheme.accent.opacity(0.55), radius: 12)
    }

    // MARK: - Controls (FF Normal / FF Max)

    private var controls: some View {
        VStack(spacing: 13) {
            HStack(spacing: 14) {
                iconTile(tab == .normal ? "scope" : "flame.fill", size: 72)
                VStack(alignment: .leading, spacing: 5) {
                    Text(tab == .normal ? "FF NORMAL" : "FF MAX")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("AIM CONTROL")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.7)
                        .foregroundStyle(AppTheme.accent)
                }
                Spacer()
            }
            .padding(18)
            .background(.black.opacity(0.54), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(AppTheme.accent.opacity(0.35)))

            HStack {
                title("PATCH OPTIONS", icon: "bolt.fill")
                Spacer()
                Text("SELECT TO ENABLE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }

            ForEach(Array((tab == .normal ? normalNames : maxNames).enumerated()), id: \.offset) { index, name in
                row(name, index: index)
            }

            HStack {
                Circle()
                    .fill(patchOperationBusy ? Color.orange : AppTheme.accent)
                    .frame(width: 7, height: 7)
                Text(patchMessage)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                Spacer()
            }
            .padding(12)
            .background(.black.opacity(0.42), in: Capsule())
        }
    }

    private func row(_ name: String, index: Int) -> some View {
        let enabled = tab == .normal ? normal[index] : max[index]
        let package = tab == .normal ? normalPackages[index] : maxPackages[index]

        return Button {
            togglePatch(packageFilename: package, index: index)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("FREE FIRE • \(tab == .normal ? "NORMAL" : "MAX")")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(AppTheme.accent)
                }

                Spacer()

                Text(enabled ? "ON" : "OFF")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(enabled ? .green : .white.opacity(0.55))

                Toggle("", isOn: .constant(enabled))
                    .labelsHidden()
                    .tint(AppTheme.accent)
                    .allowsHitTesting(false)
            }
            .padding(14)
            .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(enabled ? AppTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .opacity(patchOperationBusy ? 0.55 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(patchOperationBusy)
    }

    // MARK: - Developer tab

    private var developer: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 14) {
                    iconTile("person.crop.circle.fill", size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DEVELOPER INFO")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .tracking(1.3)
                            .foregroundStyle(AppTheme.accent)
                        Text("ATH REGEDIT")
                            .font(.system(size: 23, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
                title("DEVELOPER INFO • DESIGN 1", icon: "hammer.fill")
                HStack {
                    Text("BUILD")
                    Spacer()
                    Text("1.2")
                }
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
            }
            .padding(18)
            .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(AppTheme.accent.opacity(0.42)))

            device
            licenseValidity
        }
    }

    private var device: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("DEVICE", icon: "iphone")
            statusRow("iOS", UIDevice.current.systemVersion, icon: "iphone")
            statusRow("Device", AppInfo.machineName, icon: "cpu")
            statusRow("Support", appState.isSupported ? "SUPPORTED" : "NOT SUPPORTED", icon: "checkmark.shield")
        }
        .padding(18)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(AppTheme.accent.opacity(0.35)))
    }

    private var licenseValidity: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("KEY VALIDITY", icon: "key.fill")
            statusRow("License key", licenseManager.activeLicenseKey ?? "Not available", icon: "key")
                .textSelection(.enabled)
            statusRow("Validation", validationText, icon: validationIcon)
            statusRow("Status", licenseManager.licenseStatus, icon: "checkmark.seal")
            statusRow("Valid until", validityText, icon: "calendar")
            statusRow("Injection", licenseManager.injectionAllowed ? "ALLOWED" : "DISABLED", icon: "bolt.shield")
        }
        .padding(18)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(AppTheme.accent.opacity(0.35)))
    }

    private var validityText: String {
        guard let date = licenseManager.expirationDate else { return "No expiry reported" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMM d, yyyy, h:mm:ss a z"
        return formatter.string(from: date)
    }

    private var validationText: String {
        if licenseManager.isBusy { return "CHECKING…" }
        return licenseManager.isActive ? "VALID" : "INVALID"
    }

    private var validationIcon: String {
        if licenseManager.isBusy { return "arrow.triangle.2.circlepath" }
        return licenseManager.isActive ? "checkmark.seal.fill" : "xmark.seal.fill"
    }

    private func statusRow(_ label: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.white.opacity(0.65))
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white)
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .padding(.vertical, 3)
    }

    // MARK: - Tabs

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: item == .normal ? "scope" : item == .max ? "flame.fill" : "person.crop.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                        Text(item.rawValue)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(tab == item ? AppTheme.accent : .white)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .background(tab == item ? Color.white.opacity(0.15) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(.black.opacity(0.52), in: Capsule())
        .overlay(Capsule().stroke(AppTheme.accent.opacity(0.38)))
    }

    // MARK: - Helpers UI

    private func iconTile(_ systemName: String, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.92))
            Image(systemName: systemName)
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(AppTheme.accent)
        }
        .frame(width: size, height: size)
        .shadow(color: AppTheme.accent.opacity(0.22), radius: 9)
    }

    private func title(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .black, design: .rounded))
            .tracking(1.4)
            .foregroundStyle(AppTheme.accent)
    }

    // MARK: - Real Patch Logic

    private func isPatchActive(_ packageFilename: String) -> Bool {
        patchStore.items
            .first(where: { $0.packageURL.lastPathComponent.caseInsensitiveCompare(packageFilename) == .orderedSame })
            .flatMap { DevicePatchService.latestReceipt(projectID: $0.id) } != nil
    }

    private func syncPatchStates() {
        for (index, package) in normalPackages.enumerated() {
            if index < normal.count {
                normal[index] = isPatchActive(package)
            }
        }
        for (index, package) in maxPackages.enumerated() {
            if index < max.count {
                max[index] = isPatchActive(package)
            }
        }
    }

    private func setLocalState(index: Int, enabled: Bool) {
        // Update only the selected tab. Normal and Max intentionally have
        // independent packages and therefore independent UI state.
        if tab == .normal {
            if index < normal.count { normal[index] = enabled }
        } else if tab == .max {
            if index < max.count { max[index] = enabled }
        }
    }

    private func togglePatch(packageFilename: String, index: Int) {
        guard !patchOperationBusy else { return }

        guard let item = patchStore.items.first(where: {
            $0.packageURL.lastPathComponent.caseInsensitiveCompare(packageFilename) == .orderedSame
        }) else {
            patchMessage = "ERROR — PACKAGE NOT FOUND"
            log("patch: package not found: \(packageFilename)")
            return
        }

        let wasEnabled = tab == .normal ? normal[index] : max[index]
        if !wasEnabled && !licenseManager.injectionAllowed {
            patchMessage = "INJECTION DISABLED BY API PACKAGE POLICY"
            log("patch: application denied by API injection policy: \(packageFilename)")
            return
        }
        patchOperationBusy = true
        patchMessage = "PROCESSING — \(packageFilename)"

        let project = item.project
        let projectID = item.id

        DispatchQueue.global(qos: .userInitiated).async {
            let result: PatchActionResult
            do {
                if wasEnabled {
                    guard let receipt = DevicePatchService.latestReceipt(projectID: projectID) else {
                        DispatchQueue.main.async {
                            self.setLocalState(index: index, enabled: false)
                            self.patchMessage = "OFF — NO ACTIVE PATCH FOUND"
                            self.patchOperationBusy = false
                        }
                        return
                    }
                    try DevicePatchService.restore(receipt: receipt)
                    result = .restored
                } else {
                    guard let project else {
                        DispatchQueue.main.async {
                            self.patchStore.requestUnlock(for: item)
                            self.patchMessage = "PASSWORD REQUIRED — ENTER PACKAGE PASSWORD"
                            self.patchOperationBusy = false
                        }
                        return
                    }
                    _ = try DevicePatchService.apply(project: project)
                    result = .applied
                }
            } catch {
                result = .unavailable("FAILED — \(error.localizedDescription)")
            }

            DispatchQueue.main.async {
                switch result {
                case .applied:
                    self.setLocalState(index: index, enabled: true)
                    self.patchMessage = "Inject Successful — \(packageFilename)"
                case .restored:
                    self.setLocalState(index: index, enabled: false)
                    self.patchMessage = "Restore Successful — \(packageFilename)"
                case .unavailable(let message):
                    self.patchMessage = message
                }
                self.patchOperationBusy = false
            }
        }
    }

    private enum PatchActionResult {
        case applied
        case restored
        case unavailable(String)
    }
}

// MARK: - Backdrop

struct AnimatedHyperBackdrop: View {
    @State private var animate = false
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppTheme.pageBackground
                Circle()
                    .fill(AppTheme.accent.opacity(0.12))
                    .frame(width: 280, height: 280)
                    .blur(radius: 70)
                    .offset(x: animate ? 120 : -120, y: -proxy.size.height * 0.23)
                Circle()
                    .fill(AppTheme.secondaryAccent.opacity(0.08))
                    .frame(width: 260, height: 260)
                    .blur(radius: 80)
                    .offset(x: animate ? -100 : 100, y: proxy.size.height * 0.22)
                GridOverlay()
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                    animate = true
                }
            }
        }
    }
}

private struct GridOverlay: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let spacing: CGFloat = 44
            stride(from: CGFloat(0), through: size.width, by: spacing).forEach { x in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: CGFloat(0), through: size.height, by: spacing).forEach { y in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(AppTheme.accent.opacity(0.055)), lineWidth: 1)
        }
    }
}

// MARK: - Package Unlock Prompt

private struct PatchUnlockPrompt: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PatchProjectStore
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Package password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .onSubmit(unlock)
                        .onChange(of: password) { _ in store.clearUnlockError() }
                    if let errorKey = store.unlockErrorKey {
                        Text(AppLanguage.english.text(errorKey))
                            .font(.footnote)
                            .foregroundStyle(AppTheme.accent)
                    }
                } footer: {
                    Text("Enter the password once to unlock this 3105 package on this device.")
                }
            }
            .navigationTitle("Unlock package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock", action: unlock)
                        .disabled(password.isEmpty || store.isBusy)
                }
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        store.unlock(password: password)
    }
}
