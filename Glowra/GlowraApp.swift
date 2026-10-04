import SwiftUI
import AuthenticationServices
import Combine

let baseURL = "https://kdvlpfwvniocdujbkowp.supabase.co"
let anonKey = "sb_publishable_974HaQPl0UAQ4oDYd9bo-w_KJsp9Quz"

extension Color {
    static let glowPlum = Color(red: 0.38, green: 0.10, blue: 0.22)
    static let glowPink = Color(red: 0.91, green: 0.28, blue: 0.48)
    static let glowCream = Color(red: 0.99, green: 0.96, blue: 0.95)
    static let glowPeach = Color(red: 0.98, green: 0.88, blue: 0.81)
}

func jwtClaims(_ token: String) -> [String: Any] {
    let parts = token.split(separator: ".")
    guard parts.count > 1 else { return [:] }
    var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b.count % 4 != 0 { b += "=" }
    guard let d = Data(base64Encoded: b),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

func naira(_ n: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    return "₦" + (f.string(from: NSNumber(value: n)) ?? "\(n)")
}

func shortDate(_ value: String) -> String {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    return date?.formatted(date: .abbreviated, time: .omitted) ?? value
}

struct Product: Codable, Identifiable {
    let id: String
    let name: String
    let category: String
    let price: Int
    var brand: String? = nil
    var description: String? = nil
    var emoji: String? = nil
    var image_url: String? = nil
}

struct CartRow: Codable { let product_id: String; let quantity: Int }

struct OrderItem: Codable, Identifiable {
    var id: String { (product_id ?? name) + "-\(quantity)" }
    let product_id: String?
    let name: String
    let price: Int
    let quantity: Int
}

struct Order: Codable, Identifiable {
    let id: String
    let total: Int
    let status: String?
    let created_at: String
    let order_items: [OrderItem]?
}

struct Login: Codable {
    var access: String
    var refresh: String
    var userId: String { jwtClaims(access)["sub"] as? String ?? "" }
    var email: String { jwtClaims(access)["email"] as? String ?? "" }
    var exp: Double { jwtClaims(access)["exp"] as? Double ?? 0 }
}

final class Presenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            fatalError("No active window scene")
        }
        return scene.keyWindow ?? ASPresentationAnchor(windowScene: scene)
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var products: [Product] = []
    @Published var cart: [String: Int] = [:]
    @Published var orders: [Order] = []
    @Published var login: Login?
    @Published var message = ""
    @Published var displayName = ""
    @Published var avatarURL: String?
    @Published var memberSince = ""
    private var loops: [Task<Void, Never>] = []
    private var authSession: ASWebAuthenticationSession?
    private let presenter = Presenter()

    var cartCount: Int { cart.values.reduce(0, +) }
    var accountName: String {
        if !displayName.isEmpty { return displayName }
        return login?.email.components(separatedBy: "@").first?.capitalized ?? "Glowra shopper"
    }

    init() {
        if let d = UserDefaults.standard.data(forKey: "login"),
           let l = try? JSONDecoder().decode(Login.self, from: d) { login = l }
        Task { await start() }
    }

    func start() async {
        await loadProducts()
        if login != nil {
            if let l = login, l.exp < Date().timeIntervalSince1970 + 60 { await refresh() }
            await startSync()
        }
    }

    func setLogin(_ l: Login) {
        login = l
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: "login") }
    }

    func call(_ path: String, method: String = "GET", body: Data? = nil,
              prefer: String? = nil, retry: Bool = true) async throws -> Data {
        var r = URLRequest(url: URL(string: baseURL + path)!)
        r.httpMethod = method
        r.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let l = login { r.setValue("Bearer " + l.access, forHTTPHeaderField: "Authorization") }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let p = prefer { r.setValue(p, forHTTPHeaderField: "Prefer") }
        r.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse {
            if h.statusCode == 401, retry, login != nil {
                await refresh()
                return try await call(path, method: method, body: body, prefer: prefer, retry: false)
            }
            if h.statusCode >= 400 {
                throw NSError(domain: "api", code: h.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Error"])
            }
        }
        return data
    }

    func refresh() async {
        guard let l = login else { return }
        var r = URLRequest(url: URL(string: baseURL + "/auth/v1/token?grant_type=refresh_token")!)
        r.httpMethod = "POST"
        r.setValue(anonKey, forHTTPHeaderField: "apikey")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": l.refresh])
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let a = o["access_token"] as? String, let rt = o["refresh_token"] as? String
        else { signOut(); return }
        setLogin(Login(access: a, refresh: rt))
    }

    func signIn() {
        var c = URLComponents(string: baseURL + "/auth/v1/authorize")!
        c.queryItems = [URLQueryItem(name: "provider", value: "google"),
                        URLQueryItem(name: "redirect_to", value: "glowra://login-callback")]
        let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "glowra") { [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
                guard let url else { self.message = error?.localizedDescription ?? "Sign-in cancelled"; return }
                let items = URLComponents(string: "x://x?" + (url.fragment ?? ""))?.queryItems ?? []
                func val(_ n: String) -> String? { items.first { $0.name == n }?.value }
                guard let a = val("access_token"), let r = val("refresh_token") else {
                    self.message = "Sign-in did not return a session"; return
                }
                self.message = ""
                self.setLogin(Login(access: a, refresh: r))
                await self.startSync()
            }
        }
        s.presentationContextProvider = presenter
        s.prefersEphemeralWebBrowserSession = true
        authSession = s
        s.start()
    }

    func signOut() {
        loops.forEach { $0.cancel() }; loops = []
        login = nil; cart = [:]; orders = []
        displayName = ""; avatarURL = nil; memberSince = ""
        UserDefaults.standard.removeObject(forKey: "login")
    }

    func loadProducts() async {
        do {
            let d = try await call("/rest/v1/products?select=*&order=brand")
            products = try JSONDecoder().decode([Product].self, from: d)
            message = ""
        } catch { message = error.localizedDescription }
    }

    func loadCart() async {
        guard login != nil else { return }
        do {
            let d = try await call("/rest/v1/cart_items?select=product_id,quantity")
            let rows = try JSONDecoder().decode([CartRow].self, from: d)
            var m: [String: Int] = [:]
            rows.forEach { m[$0.product_id] = $0.quantity }
            cart = m
            message = ""
        } catch { message = error.localizedDescription }
    }

    func loadProfile() async {
        guard login != nil else { return }
        do {
            let d = try await call("/auth/v1/user")
            guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let meta = o["user_metadata"] as? [String: Any]
            displayName = meta?["full_name"] as? String ?? meta?["name"] as? String ?? ""
            avatarURL = meta?["avatar_url"] as? String ?? meta?["picture"] as? String
            if let created = o["created_at"] as? String { memberSince = shortDate(created) }
        } catch { }
    }

    func loadOrders() async {
        guard login != nil else { return }
        do {
            let d = try await call("/rest/v1/orders?select=id,total,status,created_at,order_items(product_id,name,price,quantity)&order=created_at.desc")
            orders = try JSONDecoder().decode([Order].self, from: d)
        } catch {
            orders = []
        }
    }

    func setQty(_ pid: String, _ q: Int) {
        guard let uid = login?.userId else { return }
        if q > 0 { cart[pid] = q } else { cart.removeValue(forKey: pid) }
        Task {
            do {
                if q > 0 {
                    let body = try JSONSerialization.data(withJSONObject:
                        [["user_id": uid, "product_id": pid, "quantity": q]])
                    _ = try await call("/rest/v1/cart_items?on_conflict=user_id,product_id",
                                       method: "POST", body: body, prefer: "resolution=merge-duplicates")
                } else {
                    _ = try await call("/rest/v1/cart_items?user_id=eq.\(uid)&product_id=eq.\(pid)", method: "DELETE")
                }
                message = ""
            } catch { message = error.localizedDescription }
        }
    }

    func startSync() async {
        loops.forEach { $0.cancel() }; loops = []
        await loadCart()
        await loadProfile()
        await loadOrders()
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.loadCart()
            }
        })
        loops.append(Task { [weak self] in await self?.runSocket() })
    }

    func runSocket() async {
        while !Task.isCancelled, let l = login {
            let url = URL(string: "wss://kdvlpfwvniocdujbkowp.supabase.co/realtime/v1/websocket?apikey=\(anonKey)&vsn=1.0.0")!
            let ws = URLSession.shared.webSocketTask(with: url)
            ws.resume()
            let join: [String: Any] = [
                "topic": "realtime:cart", "event": "phx_join", "ref": "1", "join_ref": "1",
                "payload": ["config": ["postgres_changes": [["event": "*", "schema": "public",
                            "table": "cart_items", "filter": "user_id=eq.\(l.userId)"]]],
                            "access_token": l.access]
            ]
            if let d = try? JSONSerialization.data(withJSONObject: join), let s = String(data: d, encoding: .utf8) {
                try? await ws.send(.string(s))
            }
            let beat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    try? await ws.send(.string("{\"topic\":\"phoenix\",\"event\":\"heartbeat\",\"payload\":{},\"ref\":\"9\"}"))
                }
            }
            while !Task.isCancelled {
                guard let msg = try? await ws.receive() else { break }
                if case .string(let t) = msg, t.contains("\"postgres_changes\""), !t.contains("phx_reply") {
                    await loadCart()
                }
            }
            beat.cancel(); ws.cancel(with: .goingAway, reason: nil)
            try? await Task.sleep(for: .seconds(3))
        }
    }
}

@main
struct GlowraApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject var store = Store()
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.login == nil {
                LoginView(store: store)
            } else {
                TabView(selection: $selectedTab) {
                    HomeView(store: store) { selectedTab = 1 }
                        .tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
                    ShopView(store: store)
                        .tabItem { Label("Shop", systemImage: "bag.fill") }.tag(1)
                    CartView(store: store)
                        .tabItem { Label("Cart", systemImage: "cart.fill") }
                        .badge(store.cartCount).tag(2)
                    AccountView(store: store)
                        .tabItem { Label("Account", systemImage: "person.crop.circle.fill") }.tag(3)
                }
                .tint(.glowPlum)
                .toolbarBackground(Color.glowCream, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            }
        }
        .preferredColorScheme(.light)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, store.login != nil else { return }
            Task {
                await store.loadCart()
                await store.loadProfile()
                await store.loadOrders()
            }
        }
    }
}

struct LoginView: View {
    @ObservedObject var store: Store
    var body: some View {
        ZStack {
            LinearGradient(colors: [.glowCream, .glowPeach], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "sparkles").font(.system(size: 48)).foregroundStyle(Color.glowPink)
                Text("Glowra").font(.system(size: 52, weight: .heavy, design: .serif)).foregroundStyle(Color.glowPlum)
                Text("Skincare and beauty, picked for glowing skin.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 36)
                Button { store.signIn() } label: {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.checkmark")
                        .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent).tint(.glowPlum).controlSize(.large).padding(.horizontal, 34)
                if !store.message.isEmpty {
                    Text(store.message).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }
                Text("Demo shop · No real payments are taken")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }
}

struct HomeView: View {
    @ObservedObject var store: Store
    let openShop: () -> Void
    var featured: [Product] { Array(store.products.prefix(6)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Skincare and beauty, picked for glowing skin.")
                            .font(.system(size: 34, weight: .heavy, design: .serif)).foregroundStyle(Color.glowPlum)
                        Text("Serums, cleansers, sunscreens and lip care from brands you love.")
                            .foregroundStyle(.secondary)
                        Button("Shop all products", action: openShop)
                            .buttonStyle(.borderedProminent).tint(.glowPlum)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [Color.glowPink.opacity(0.16), .glowPeach], startPoint: .leading, endPoint: .trailing))
                    .clipShape(RoundedRectangle(cornerRadius: 26))

                    HStack {
                        Text("Featured for you").font(.title2.bold()).foregroundStyle(Color.glowPlum)
                        Spacer()
                        Button("See all", action: openShop).font(.subheadline.bold()).foregroundStyle(Color.glowPlum)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(featured) { product in
                                CompactProductCard(product: product, store: store)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Shop by category").font(.title2.bold()).foregroundStyle(Color.glowPlum)
                        HStack(spacing: 12) {
                            CategoryTile(title: "Skincare", icon: "drop.fill", color: .glowPink, action: openShop)
                            CategoryTile(title: "Beauty", icon: "sparkles", color: .glowPlum, action: openShop)
                        }
                    }
                }
                .padding()
            }
            .background(Color.glowCream.ignoresSafeArea())
            .navigationTitle("Glowra")
        }
    }
}

struct CategoryTile: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.title)
                Text(title).font(.headline)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity).padding(.vertical, 24)
            .background(.white).clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

struct ProductImage: View {
    let product: Product
    var body: some View {
        ZStack {
            Color.white
            if let image = product.image_url, let url = URL(string: image) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(10)
                    } else if phase.error != nil {
                        Text(product.emoji ?? "✨").font(.system(size: 42))
                    } else {
                        ProgressView().tint(.glowPlum)
                    }
                }
            } else {
                Text(product.emoji ?? "✨").font(.system(size: 42))
            }
        }
    }
}

struct CompactProductCard: View {
    let product: Product
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductImage(product: product).frame(width: 180, height: 155)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text((product.brand ?? "Glowra").uppercased()).font(.caption2.bold()).foregroundStyle(Color.glowPink)
            Text(product.name).font(.headline).lineLimit(2).frame(width: 180, alignment: .leading)
            HStack {
                Text(naira(product.price)).font(.subheadline.bold())
                Spacer()
                Button { store.setQty(product.id, (store.cart[product.id] ?? 0) + 1) } label: {
                    Image(systemName: "plus").fontWeight(.bold).padding(7).background(Color.glowPlum).foregroundStyle(.white).clipShape(Circle())
                }
            }.frame(width: 180)
        }
        .padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

struct ShopView: View {
    @ObservedObject var store: Store
    @State private var search = ""
    @State private var category = "All"
    @State private var brand = "All"

    var categories: [String] { ["All"] + Array(Set(store.products.map(\.category))).sorted() }
    var brands: [String] { ["All"] + Array(Set(store.products.compactMap(\.brand))).sorted() }
    var filtered: [Product] {
        store.products.filter { p in
            (category == "All" || p.category == category) &&
            (brand == "All" || p.brand == brand) &&
            (search.isEmpty || p.name.localizedCaseInsensitiveContains(search) || (p.brand ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        ForEach(categories, id: \.self) { item in
                            Button(item) { category = item }
                                .buttonStyle(.borderedProminent)
                                .tint(category == item ? .glowPlum : Color.white)
                                .foregroundStyle(category == item ? Color.white : .glowPlum)
                        }
                        Spacer()
                        Menu {
                            ForEach(brands, id: \.self) { item in Button(item) { brand = item } }
                        } label: {
                            Label(brand == "All" ? "Brand" : brand, systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }
                    .font(.subheadline)
                    .padding(.horizontal)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 14)], spacing: 14) {
                        ForEach(filtered) { product in
                            ProductCard(product: product, store: store)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .background(Color.glowCream.ignoresSafeArea())
            .navigationTitle("Shop")
            .searchable(text: $search, prompt: "Search products or brands")
        }
    }
}

struct ProductCard: View {
    let product: Product
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductImage(product: product).frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text((product.brand ?? "Glowra").uppercased()).font(.caption2.bold()).foregroundStyle(Color.glowPink)
            Text(product.name).font(.headline).lineLimit(2)
            Text(product.description ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text(naira(product.price)).font(.subheadline.bold())
                Spacer()
                Button { store.setQty(product.id, (store.cart[product.id] ?? 0) + 1) } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }.tint(.glowPlum)
            }
        }
        .padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

struct CartView: View {
    @ObservedObject var store: Store
    var items: [Product] { store.products.filter { store.cart[$0.id] != nil } }
    var total: Int { items.reduce(0) { $0 + $1.price * (store.cart[$1.id] ?? 0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if items.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "bag").font(.system(size: 52)).foregroundStyle(Color.glowPink)
                            Text("Your cart is empty").font(.title2.bold())
                            Text("Products you add on the website will appear here too.")
                                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }.padding(.top, 90)
                    } else {
                        ForEach(items) { product in
                            HStack(spacing: 12) {
                                ProductImage(product: product).frame(width: 74, height: 74).clipShape(RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(product.name).font(.headline).lineLimit(2)
                                    Text(naira(product.price)).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Stepper("\(store.cart[product.id] ?? 0)",
                                        value: Binding(get: { store.cart[product.id] ?? 0 },
                                                       set: { store.setQty(product.id, $0) }), in: 0...99)
                                    .labelsHidden()
                                Text("\(store.cart[product.id] ?? 0)").font(.headline).frame(minWidth: 22)
                            }
                            .padding().background(.white).clipShape(RoundedRectangle(cornerRadius: 18))
                        }
                        VStack(spacing: 12) {
                            HStack { Text("Total").font(.title3.bold()); Spacer(); Text(naira(total)).font(.title3.bold()) }
                            Text("Your cart stays synchronized with the Glowra website.")
                                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding().background(Color.glowPeach.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    if !store.message.isEmpty {
                        Text(store.message).font(.footnote).foregroundStyle(.red).padding()
                    }
                }
                .padding()
            }
            .background(Color.glowCream.ignoresSafeArea())
            .navigationTitle("Cart")
        }
    }
}

struct AccountView: View {
    @ObservedObject var store: Store

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        if let value = store.avatarURL, let url = URL(string: value) {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() }
                                else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(Color.glowPink) }
                            }
                            .frame(width: 96, height: 96).clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle.fill").resizable().frame(width: 96, height: 96).foregroundStyle(Color.glowPink)
                        }
                        Text(store.accountName).font(.title2.bold()).foregroundStyle(Color.glowPlum)
                        Text(store.login?.email ?? "").foregroundStyle(.secondary)
                        HStack(spacing: 28) {
                            VStack { Text("\(store.orders.count)").font(.title2.bold()); Text("Orders").font(.caption).foregroundStyle(.secondary) }
                            if !store.memberSince.isEmpty {
                                VStack { Text(store.memberSince).font(.subheadline.bold()); Text("Member since").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity).padding(24).background(.white).clipShape(RoundedRectangle(cornerRadius: 24))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("My orders").font(.title2.bold()).foregroundStyle(Color.glowPlum)
                        if store.orders.isEmpty {
                            Text("No orders yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                .padding().background(.white).clipShape(RoundedRectangle(cornerRadius: 16))
                        } else {
                            ForEach(store.orders) { order in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("#" + String(order.id.prefix(8)).uppercased()).font(.headline)
                                        Spacer()
                                        Text(shortDate(order.created_at)).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    ForEach(order.order_items ?? []) { item in
                                        HStack {
                                            Text("\(item.name) × \(item.quantity)").font(.subheadline)
                                            Spacer()
                                            Text(naira(item.price * item.quantity)).font(.subheadline)
                                        }
                                    }
                                    Divider()
                                    HStack {
                                        Text((order.status ?? "placed").capitalized).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(naira(order.total)).fontWeight(.bold)
                                    }
                                }
                                .padding().background(.white).clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }

                    Button(role: .destructive) { store.signOut() } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered).controlSize(.large)

                    VStack(spacing: 6) {
                        Text("Glowra is a demo store created for a class project.")
                        Text("No real payments are taken.")
                    }.font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
            .background(Color.glowCream.ignoresSafeArea())
            .navigationTitle("Account")
            .refreshable {
                await store.loadProfile()
                await store.loadOrders()
            }
            .task {
                await store.loadProfile()
                await store.loadOrders()
            }
        }
    }
}
