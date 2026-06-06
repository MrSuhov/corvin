import Foundation
import StoreKit
import Combine

/// Manages Corvin Pro purchase state.
/// Uses StoreKit 2 on macOS 12+ / iOS 15+, StoreKit 1 fallback on macOS 11.
///
/// Identification & sync model (by design — read before changing):
/// - Single non-consumable product: `com.corvin.pro`.
/// - The purchase is tied to the buyer's Apple ID. Apple stores and verifies the
///   entitlement; we read it via StoreKit 2 `Transaction.currentEntitlements`
///   and trust only verified results (`VerificationResult` → `checkVerified`).
/// - There is NO backend, no user accounts, no `appAccountToken`, and no receipt
///   server. The app never learns the buyer's identity.
/// - Cross-device sync = StoreKit restore: `AppStore.sync()` followed by an
///   entitlement check, on the same Apple ID (see `restore()` / `triggerRestore()`).
///   `isPro` is also cached in UserDefaults (App Group on iOS) purely as a fast-path
///   cache for launch — Apple's entitlement is the source of truth, not this cache.
/// - Future option: if per-purchaser identity is ever needed (named thanks,
///   cross-platform outside one Apple ID, analytics), that would require our own
///   accounts + `transaction.appAccountToken` + the App Store Server API.
final class ProManager: NSObject, ObservableObject {
    static let shared = ProManager()

    static let productID = "com.corvin.pro"

    @Published private(set) var isPro: Bool {
        didSet { userDefaults.set(isPro, forKey: Self.proStatusKey) }
    }
    /// Stores StoreKit 2 Product (typed as Any to avoid macOS 11 availability issues)
    private var _proProduct: Any?

    @available(macOS 12.0, iOS 15.0, *)
    var proProduct: Product? {
        get { _proProduct as? Product }
        set { _proProduct = newValue }
    }

    @Published private(set) var purchaseInProgress = false
    @Published private(set) var errorMessage: String?

    /// One-shot flag set to true ONLY on a genuinely NEW purchase (not restore).
    /// UI observes this to show the celebratory thank-you moment, then calls
    /// `acknowledgePurchase()` to reset it.
    @Published private(set) var didJustPurchase: Bool = false

    private static let proStatusKey = "corvin_pro_unlocked"

    private var userDefaults: UserDefaults {
        #if os(iOS)
        return UserDefaults(suiteName: "group.com.corvinvoice.app") ?? .standard
        #else
        return .standard
        #endif
    }

    private var transactionListener: Any?

    // MARK: - StoreKit 1 fallback (macOS 11)
    #if os(macOS)
    private var sk1Products: [SKProduct] = []
    private var sk1PurchaseCompletion: ((Bool) -> Void)?
    #endif

    override init() {
        // Load cached status
        #if os(iOS)
        let defaults = UserDefaults(suiteName: "group.com.corvinvoice.app") ?? .standard
        #else
        let defaults = UserDefaults.standard
        #endif
        self.isPro = defaults.bool(forKey: Self.proStatusKey)

        super.init()

        if #available(macOS 12.0, iOS 15.0, *) {
            startTransactionListener()
            Task { await loadProducts() }
            Task { await verifyEntitlements() }
        } else {
            #if os(macOS)
            setupStoreKit1()
            #endif
        }
    }

    // MARK: - StoreKit 2 (macOS 12+ / iOS 15+)

    @available(macOS 12.0, iOS 15.0, *)
    private func loadProducts() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            await MainActor.run {
                self.proProduct = products.first
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    @available(macOS 12.0, iOS 15.0, *)
    func purchase() async {
        guard let product = proProduct else { return }

        await MainActor.run {
            purchaseInProgress = true
            errorMessage = nil
        }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await MainActor.run {
                    self.isPro = true
                    self.purchaseInProgress = false
                    self.didJustPurchase = true
                }
            case .userCancelled:
                await MainActor.run { self.purchaseInProgress = false }
            case .pending:
                await MainActor.run { self.purchaseInProgress = false }
            @unknown default:
                await MainActor.run { self.purchaseInProgress = false }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.purchaseInProgress = false
            }
        }
    }

    @available(macOS 12.0, iOS 15.0, *)
    func restore() async {
        do {
            try await AppStore.sync()
            await verifyEntitlements()
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    @available(macOS 12.0, iOS 15.0, *)
    private func verifyEntitlements() async {
        var found = false
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result),
               transaction.productID == Self.productID {
                found = true
                break
            }
        }
        let isEntitled = found
        await MainActor.run {
            self.isPro = isEntitled
        }
    }

    @available(macOS 12.0, iOS 15.0, *)
    private func startTransactionListener() {
        transactionListener = Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self = self else { return }
                if let transaction = try? self.checkVerified(result),
                   transaction.productID == Self.productID {
                    await transaction.finish()
                    await MainActor.run {
                        self.isPro = true
                        self.didJustPurchase = true
                    }
                }
            }
        }
    }

    /// Reset the one-shot purchase signal after the UI has shown the celebratory moment.
    func acknowledgePurchase() {
        didJustPurchase = false
    }

    @available(macOS 12.0, iOS 15.0, *)
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - StoreKit 1 fallback (macOS 11)

    #if os(macOS)
    private func setupStoreKit1() {
        SKPaymentQueue.default().add(self)
        let request = SKProductsRequest(productIdentifiers: [Self.productID])
        request.delegate = self
        request.start()
    }

    func purchaseSK1(completion: @escaping (Bool) -> Void) {
        guard let product = sk1Products.first else {
            completion(false)
            return
        }
        sk1PurchaseCompletion = completion
        purchaseInProgress = true
        errorMessage = nil
        let payment = SKPayment(product: product)
        SKPaymentQueue.default().add(payment)
    }

    func restoreSK1() {
        SKPaymentQueue.default().restoreCompletedTransactions()
    }
    #endif

    /// Formatted price string for the Pro product
    var priceString: String {
        if #available(macOS 12.0, iOS 15.0, *) {
            return (self._proProduct as? Product)?.displayPrice ?? "$0.99"
        } else {
            #if os(macOS)
            if let product = sk1Products.first {
                let formatter = NumberFormatter()
                formatter.numberStyle = .currency
                formatter.locale = product.priceLocale
                return formatter.string(from: product.price) ?? "$0.99"
            }
            #endif
            return "$0.99"
        }
    }

    /// Trigger purchase from UI (works on all OS versions)
    func triggerPurchase(completion: @escaping (Bool) -> Void) {
        if #available(macOS 12.0, iOS 15.0, *) {
            Task {
                await purchase()
                completion(self.isPro)
            }
        } else {
            #if os(macOS)
            purchaseSK1(completion: completion)
            #else
            completion(false)
            #endif
        }
    }

    /// Trigger restore from UI (works on all OS versions)
    func triggerRestore() {
        if #available(macOS 12.0, iOS 15.0, *) {
            Task { await restore() }
        } else {
            #if os(macOS)
            restoreSK1()
            #endif
        }
    }
}

// MARK: - StoreKit 1 Delegates (macOS)

#if os(macOS)
extension ProManager: SKProductsRequestDelegate {
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        DispatchQueue.main.async {
            self.sk1Products = response.products
        }
    }
}

extension ProManager: SKPaymentTransactionObserver {
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            switch transaction.transactionState {
            case .purchased:
                if transaction.payment.productIdentifier == Self.productID {
                    DispatchQueue.main.async {
                        self.isPro = true
                        self.purchaseInProgress = false
                        self.didJustPurchase = true
                        self.sk1PurchaseCompletion?(true)
                        self.sk1PurchaseCompletion = nil
                    }
                }
                queue.finishTransaction(transaction)
            case .restored:
                if transaction.payment.productIdentifier == Self.productID {
                    DispatchQueue.main.async {
                        self.isPro = true
                        self.purchaseInProgress = false
                        self.sk1PurchaseCompletion?(true)
                        self.sk1PurchaseCompletion = nil
                    }
                }
                queue.finishTransaction(transaction)
            case .failed:
                DispatchQueue.main.async {
                    self.errorMessage = transaction.error?.localizedDescription
                    self.purchaseInProgress = false
                    self.sk1PurchaseCompletion?(false)
                    self.sk1PurchaseCompletion = nil
                }
                queue.finishTransaction(transaction)
            case .deferred, .purchasing:
                break
            @unknown default:
                break
            }
        }
    }
}
#endif
