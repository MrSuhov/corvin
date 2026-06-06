import SwiftUI

struct ProPaywallView: View {
    @ObservedObject var proManager = ProManager.shared
    @Environment(\.presentationMode) var presentationMode

    /// Drives the spring scale/opacity animation of the celebratory moment.
    @State private var celebrationVisible = false

    /// Cancellable auto-dismiss timer so it never fires after the paywall is gone.
    @State private var dismissWorkItem: DispatchWorkItem?

    /// macOS is a menubar agent (LSUIElement) with no Dock icon, so the
    /// "change the app icon" promise in the cross-platform copy can't be kept
    /// there — use a macOS-specific description that drops it.
    private var descriptionKey: String {
        #if os(macOS)
        "pro.description.macos"
        #else
        "pro.description"
        #endif
    }

    var body: some View {
        ZStack {
            paywallContent

            if proManager.didJustPurchase {
                celebrationOverlay
            }
        }
        .onChange(of: proManager.didJustPurchase) { didJustPurchase in
            guard didJustPurchase else { return }
            startCelebration()
        }
        .onAppear {
            // `didJustPurchase` may already be true (external / Ask-to-Buy /
            // App-Store-initiated purchases set it via the background listener
            // while no paywall is presented), so `.onChange` would never fire.
            if proManager.didJustPurchase {
                startCelebration()
            }
        }
        .onDisappear {
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
        }
    }

    /// Plays the celebration animation and schedules a cancellable auto-dismiss.
    /// Idempotent: a no-op if the celebration is already running.
    private func startCelebration() {
        guard dismissWorkItem == nil else { return }

        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            celebrationVisible = true
        }

        let workItem = DispatchWorkItem {
            // No-op if the user already closed the paywall manually.
            guard proManager.didJustPurchase else { return }
            proManager.acknowledgePurchase()
            presentationMode.wrappedValue.dismiss()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
    }

    // MARK: - Celebratory moment (shown on a brand-new purchase)

    private var celebrationOverlay: some View {
        ZStack {
            #if os(macOS)
            Color(NSColor.windowBackgroundColor).opacity(0.98)
            #else
            Color(UIColor.systemBackground).opacity(0.98)
            #endif

            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.green)
                    .scaleEffect(celebrationVisible ? 1.0 : 0.5)
                    .opacity(celebrationVisible ? 1.0 : 0.0)

                Text("pro.thankYou".localized)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .opacity(celebrationVisible ? 1.0 : 0.0)

                Text("pro.thankYou.detail".localized)
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .opacity(celebrationVisible ? 1.0 : 0.0)
            }
        }
        .ignoresSafeArea()
        #if os(macOS)
        .frame(width: 380, height: 480)
        #endif
    }

    private var paywallContent: some View {
        VStack(spacing: 20) {
            Spacer()

            // Icon
            Image(systemName: "star.fill")
                .font(.system(size: 50))
                .foregroundColor(.orange)

            // Title
            Text("pro.title".localized)
                .font(.title.bold())

            Text("pro.subtitle".localized)
                .font(.headline)
                .foregroundColor(.secondary)

            // Description
            Text(descriptionKey.localized)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 24)

            // Features
            #if os(iOS)
            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "app.badge.fill", text: "pro.feature.icon".localized)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            #endif

            Spacer()

            // Error
            if let error = proManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if proManager.isPro {
                // Already Pro
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.green)
                    Text("pro.thankYou".localized)
                        .font(.headline)
                }

                Button("common.close".localized) {
                    presentationMode.wrappedValue.dismiss()
                }
                .payButtonStyle(prominent: false)
            } else {
                // Buy button
                Button(action: {
                    proManager.triggerPurchase { _ in }
                }) {
                    if proManager.purchaseInProgress {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    } else {
                        Text("pro.buy".localized(with: proManager.priceString))
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .payButtonStyle(prominent: true)
                .disabled(proManager.purchaseInProgress)
                .padding(.horizontal, 32)

                // Restore button
                Button("pro.restore".localized) {
                    proManager.triggerRestore()
                }
                .font(.caption)
                .foregroundColor(.secondary)

                // Close button
                Button("common.close".localized) {
                    presentationMode.wrappedValue.dismiss()
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer().frame(height: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .frame(width: 380, height: 480)
        #endif
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 24)
            Text(text)
        }
    }
}

// MARK: - Cross-platform button style

private extension View {
    @ViewBuilder
    func payButtonStyle(prominent: Bool) -> some View {
        #if os(iOS)
        if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        if #available(macOS 12.0, *) {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        } else {
            if prominent {
                self
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                    .buttonStyle(.plain)
            } else {
                self
            }
        }
        #endif
    }
}
