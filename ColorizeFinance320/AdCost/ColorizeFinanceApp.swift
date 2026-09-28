import SwiftUI
import SwiftData

// MARK: - Models

enum MaterialUnit: String, CaseIterable, Codable, Identifiable {
    case piece = "шт", meter = "м", squareMeter = "м²", sheet = "лист", kilogram = "кг", liter = "л", roll = "рулон", set = "комплект"
    var id: String { rawValue }
}

enum ProductType: String, CaseIterable, Identifiable {
    case banner = "Баннер"
    case vinyl = "Плёнка / наклейка"
    case lightbox = "Световой короб"
    case letters = "Буквы"
    case printing3D = "3D-печать"
    case alucobond = "Фон из алюкобонда"
    case pvcBackground = "Фон из ПВХ"
    case perforated = "Перфоплёнка"
    case vinylMaterial = "Винил"
    case oracal = "Оракал"
    case custom = "Другое"
    var id: String { rawValue }
}

enum OrderStatus: String, CaseIterable, Identifiable {
    case estimate = "Расчёт"
    case confirmed = "Подтверждён"
    case production = "Производство"
    case installation = "Монтаж"
    case ready = "Готов"
    case paid = "Оплачен"
    var id: String { rawValue }
}

enum CostCategory: String, CaseIterable, Identifiable {
    case material = "Материал", labor = "Работа", installation = "Монтаж", delivery = "Доставка", other = "Другое"
    var id: String { rawValue }
}

@Model
final class Material {
    var id: UUID
    var name: String
    var category: String
    var unitRaw: String
    var purchasePrice: Double
    var defaultWastePercent: Double
    var stockQuantity: Double
    var createdAt: Date
    var updatedAt: Date

    init(name: String, category: String = "Общее", unit: MaterialUnit = .squareMeter, purchasePrice: Double, defaultWastePercent: Double = 10, stockQuantity: Double = 0) {
        id = UUID(); self.name = name; self.category = category; unitRaw = unit.rawValue
        self.purchasePrice = purchasePrice; self.defaultWastePercent = defaultWastePercent; self.stockQuantity = stockQuantity
        createdAt = .now; updatedAt = .now
    }
}

@Model
final class AdOrder {
    var id: UUID
    var number: Int
    var title: String
    var clientName: String
    var productTypeRaw: String
    var statusRaw: String
    var widthMeters: Double
    var heightMeters: Double
    var salePrice: Double
    var depositAmount: Double
    var desiredMarginPercent: Double
    var createdAt: Date
    var dueDate: Date?
    var notes: String

    @Relationship(deleteRule: .cascade, inverse: \CostLine.order)
    var costLines: [CostLine] = []

    init(number: Int, title: String, clientName: String = "", productType: ProductType = .custom, status: OrderStatus = .estimate, widthMeters: Double = 0, heightMeters: Double = 0, salePrice: Double = 0, depositAmount: Double = 0, desiredMarginPercent: Double = 40, notes: String = "") {
        id = UUID(); self.number = number; self.title = title; self.clientName = clientName
        productTypeRaw = productType.rawValue; statusRaw = status.rawValue; self.widthMeters = widthMeters; self.heightMeters = heightMeters
        self.salePrice = salePrice; self.depositAmount = max(0, depositAmount); self.desiredMarginPercent = desiredMarginPercent
        createdAt = .now; dueDate = nil; self.notes = notes
    }

    var area: Double { max(0, widthMeters) * max(0, heightMeters) }
    var totalCost: Double { costLines.reduce(0) { $0 + $1.totalCost } }
    var profit: Double { salePrice - totalCost }
    var balance: Double { max(0, salePrice - depositAmount) }
}

@Model
final class CostLine {
    var id: UUID
    var title: String
    var categoryRaw: String
    var quantity: Double
    var unitRaw: String
    var unitCost: Double
    var wastePercent: Double
    var createdAt: Date
    var order: AdOrder?

    init(title: String, category: CostCategory, quantity: Double, unit: MaterialUnit, unitCost: Double, wastePercent: Double = 0, order: AdOrder? = nil) {
        id = UUID(); self.title = title; categoryRaw = category.rawValue; self.quantity = quantity; unitRaw = unit.rawValue
        self.unitCost = unitCost; self.wastePercent = wastePercent; createdAt = .now; self.order = order
    }

    var adjustedQuantity: Double { max(0, quantity) * (1 + max(0, wastePercent) / 100) }
    var totalCost: Double { adjustedQuantity * max(0, unitCost) }
}

@Model
final class CompanyExpense {
    var id: UUID
    var title: String
    var category: String
    var amount: Double
    var date: Date
    var notes: String
    init(title: String, category: String = "Прочее", amount: Double, date: Date = .now, notes: String = "") {
        id = UUID(); self.title = title; self.category = category; self.amount = amount; self.date = date; self.notes = notes
    }
}

@Model
final class Client {
    var id: UUID
    var name: String
    var phone: String
    var company: String
    var notes: String
    var createdAt: Date
    init(name: String, phone: String = "", company: String = "", notes: String = "") {
        id = UUID(); self.name = name; self.phone = phone; self.company = company; self.notes = notes; createdAt = .now
    }
}

// MARK: - Styling

enum CF {
    static let red = Color(red: 1, green: 0.13, blue: 0.12)
    static let bg = Color(uiColor: .systemGroupedBackground)

    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "KZT").precision(.fractionLength(0)))
    }
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            LinearGradient(
                colors: [CF.red.opacity(0.055), Color.blue.opacity(0.025), Color.clear],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
        }.ignoresSafeArea()
    }
}

struct GlassCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

struct MetricCard: View {
    let title: String, value: String, icon: String
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CF.red)
                    .frame(width: 42, height: 42)
                    .background(CF.red.opacity(0.1), in: Circle())
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.title2.bold()).minimumScaleFactor(0.7)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - App

@main
struct ColorizeFinanceApp: App {
    private let container: ModelContainer
    @StateObject private var auth: AuthController
    @StateObject private var sync: CloudSyncCoordinator

    init() {
        do {
            let value = try ModelContainer(for: Material.self, AdOrder.self, CostLine.self, CompanyExpense.self, Client.self)
            container = value
            _auth = StateObject(wrappedValue: AuthController())
            _sync = StateObject(wrappedValue: CloudSyncCoordinator(container: value))
        } catch {
            fatalError("SwiftData: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AccountRootView()
                .environmentObject(auth)
                .environmentObject(sync)
        }
        .modelContainer(container)
    }
}

enum MainTab: String, CaseIterable, Identifiable {
    case dashboard = "Главная", orders = "Заказы", calculator = "Калькулятор", materials = "Материалы", more = "Ещё"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2.fill"
        case .orders: "doc.text.fill"
        case .calculator: "function"
        case .materials: "shippingbox.fill"
        case .more: "ellipsis"
        }
    }
}

struct AdaptiveRootView: View {
    @State private var tab: MainTab = .dashboard
    var body: some View {
        ZStack {
            AppBackground()
            TabView(selection: $tab) {
                NavigationStack { DashboardView() }.tag(MainTab.dashboard)
                NavigationStack { OrdersView() }.tag(MainTab.orders)
                NavigationStack { CalculatorView() }.tag(MainTab.calculator)
                NavigationStack { MaterialsView() }.tag(MainTab.materials)
                NavigationStack { MoreView() }.tag(MainTab.more)
            }
            .toolbar(.hidden, for: .tabBar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(MainTab.allCases) { item in
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { tab = item }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon).font(.system(size: 17, weight: .semibold))
                            Text(item.rawValue).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
                        }
                        .foregroundStyle(tab == item ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background {
                            if tab == item {
                                RoundedRectangle(cornerRadius: 17, style: .continuous).fill(CF.red)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
            .padding(5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .tint(CF.red)
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @Query private var orders: [AdOrder]
    @Query private var expenses: [CompanyExpense]

    private var orderCosts: Double { orders.reduce(0) { $0 + $1.totalCost } }
    private var companyExpenses: Double { expenses.reduce(0) { $0 + $1.amount } }
    private var totalExpenses: Double { orderCosts + companyExpenses }
    private var totalRevenue: Double { orders.reduce(0) { $0 + $1.salePrice } }
    private var totalProfit: Double { totalRevenue - totalExpenses }
    private var deposits: Double { orders.reduce(0) { $0 + min($1.depositAmount, $1.salePrice) } }
    private var balance: Double { orders.reduce(0) { $0 + $1.balance } }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 16) {
                    GlassCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Colorize Finance").font(.system(size: 28, weight: .bold, design: .rounded))
                                Text("Финансы рекламного агентства").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("C").font(.title.bold()).foregroundStyle(.white)
                                .frame(width: 54, height: 54).background(CF.red, in: Circle())
                        }
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        MetricCard(title: "Общие расходы", value: CF.money(totalExpenses), icon: "creditcard.fill")
                        MetricCard(title: "Общая прибыль", value: CF.money(totalProfit), icon: "chart.line.uptrend.xyaxis")
                        MetricCard(title: "Получено задатков", value: CF.money(deposits), icon: "banknote.fill")
                        MetricCard(title: "Остаток по заказам", value: CF.money(balance), icon: "hourglass")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Последние заказы").font(.title3.bold())
                                Text("Недавняя активность").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        GlassCard {
                            if orders.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "doc.badge.plus").font(.system(size: 42)).foregroundStyle(.secondary)
                                    Text("Заказов пока нет").font(.headline)
                                    Text("Создайте первый заказ или рассчитайте буквы в калькуляторе.")
                                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(.vertical, 28)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(orders.sorted(by: { $0.createdAt > $1.createdAt }).prefix(5)) { order in
                                        NavigationLink { OrderDetailView(order: order) } label: {
                                            OrderRow(order: order)
                                        }.buttonStyle(.plain)
                                        if order.id != orders.sorted(by: { $0.createdAt > $1.createdAt }).prefix(5).last?.id {
                                            Divider().opacity(0.35)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }.padding(16).padding(.bottom, 20)
            }
        }
        .navigationTitle("Главная")
        .toolbar {
            NavigationLink { NewOrderView() } label: { Image(systemName: "plus").fontWeight(.semibold) }
        }
    }
}

struct OrderRow: View {
    let order: AdOrder
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("#\(order.number) · \(order.title)").font(.headline).foregroundStyle(.primary)
                Text(order.clientName.isEmpty ? order.productTypeRaw : order.clientName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(CF.money(order.salePrice)).font(.subheadline.bold()).foregroundStyle(.primary)
                Text(order.statusRaw).font(.caption2).foregroundStyle(CF.red)
            }
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }.padding(.vertical, 10)
    }
}

// MARK: - Orders

struct OrdersView: View {
    @Query(sort: \AdOrder.number, order: .reverse) private var orders: [AdOrder]
    @State private var search = ""
    @State private var showingNew = false

    private var filtered: [AdOrder] {
        guard !search.isEmpty else { return orders }
        return orders.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.clientName.localizedCaseInsensitiveContains(search) || String($0.number).contains(search) }
    }

    var body: some View {
        ZStack {
            AppBackground()
            if filtered.isEmpty {
                ContentUnavailableView("Нет заказов", systemImage: "doc.text", description: Text("Создайте заказ или используйте калькулятор."))
            } else {
                List {
                    ForEach(filtered) { order in
                        NavigationLink { OrderDetailView(order: order) } label: { OrderRow(order: order) }
                            .listRowBackground(Color.clear)
                    }
                }.scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Заказы")
        .searchable(text: $search, prompt: "Номер, клиент или заказ")
        .toolbar { Button { showingNew = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $showingNew) { NewOrderView() }
    }
}

struct NewOrderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \AdOrder.number, order: .reverse) private var orders: [AdOrder]

    @State private var title = ""
    @State private var client = ""
    @State private var type: ProductType = .custom
    @State private var width = 0.0
    @State private var height = 0.0
    @State private var price = 0.0
    @State private var deposit = 0.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Заказ") {
                    TextField("Название", text: $title)
                    TextField("Клиент", text: $client)
                    Picker("Тип", selection: $type) { ForEach(ProductType.allCases) { Text($0.rawValue).tag($0) } }
                }
                if type != .letters {
                    Section("Размер") {
                        TextField("Ширина, м", value: $width, format: .number).keyboardType(.decimalPad)
                        TextField("Высота, м", value: $height, format: .number).keyboardType(.decimalPad)
                    }
                }
                Section("Финансы") {
                    TextField("Цена клиенту", value: $price, format: .number).keyboardType(.decimalPad)
                    TextField("Задаток", value: $deposit, format: .number).keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Новый заказ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        let next = (orders.first?.number ?? 0) + 1
                        context.insert(AdOrder(number: next, title: title.isEmpty ? "Новый заказ" : title, clientName: client, productType: type, widthMeters: width, heightMeters: height, salePrice: max(0, price), depositAmount: max(0, deposit)))
                        try? context.save(); dismiss()
                    }
                }
            }
        }.tint(CF.red)
    }
}

struct OrderDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var order: AdOrder
    @State private var addCost = false

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 14) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Заказ #\(order.number)").font(.caption.bold()).foregroundStyle(CF.red)
                                    Text(order.title).font(.title2.bold())
                                }
                                Spacer()
                                Text(order.statusRaw).font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 6).background(CF.red.opacity(0.1), in: Capsule())
                            }
                            HStack {
                                mini("Цена", CF.money(order.salePrice))
                                mini("Прибыль", CF.money(order.profit))
                                mini("Остаток", CF.money(order.balance))
                            }
                        }
                    }

                    GlassCard {
                        VStack(spacing: 12) {
                            TextField("Название", text: $order.title).textFieldStyle(.roundedBorder)
                            TextField("Клиент", text: $order.clientName).textFieldStyle(.roundedBorder)
                            Picker("Статус", selection: $order.statusRaw) { ForEach(OrderStatus.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                            Picker("Тип", selection: $order.productTypeRaw) { ForEach(ProductType.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                        }
                    }

                    GlassCard {
                        VStack(spacing: 10) {
                            valueRow("Себестоимость", CF.money(order.totalCost))
                            TextField("Цена клиенту", value: $order.salePrice, format: .number).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                            TextField("Задаток", value: $order.depositAmount, format: .number).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                            valueRow("Остаток", CF.money(order.balance))
                            valueRow("Прибыль", CF.money(order.profit))
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Материалы и работа").font(.headline)
                                Spacer()
                                Button { addCost = true } label: { Label("Добавить", systemImage: "plus") }
                            }
                            if order.costLines.isEmpty {
                                Text("Затрат пока нет").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
                            } else {
                                ForEach(order.costLines) { line in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(line.title).font(.subheadline.bold())
                                            Text("\(CF.number(line.adjustedQuantity)) \(line.unitRaw) · \(line.categoryRaw)").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(CF.money(line.totalCost)).bold()
                                    }.padding(.vertical, 6)
                                }
                            }
                        }
                    }
                }.padding(16)
            }
        }
        .navigationTitle(order.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button(role: .destructive) {
                    context.delete(order); try? context.save(); dismiss()
                } label: { Label("Удалить заказ", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .sheet(isPresented: $addCost) { AddCostView(order: order) }
        .onDisappear { try? context.save() }
    }

    private func mini(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).bold() }
    }
}

struct AddCostView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let order: AdOrder
    @State private var title = ""
    @State private var category: CostCategory = .material
    @State private var qty = 1.0
    @State private var unit: MaterialUnit = .piece
    @State private var unitCost = 0.0
    @State private var waste = 0.0

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $title)
                Picker("Категория", selection: $category) { ForEach(CostCategory.allCases) { Text($0.rawValue).tag($0) } }
                TextField("Количество", value: $qty, format: .number).keyboardType(.decimalPad)
                Picker("Единица", selection: $unit) { ForEach(MaterialUnit.allCases) { Text($0.rawValue).tag($0) } }
                TextField("Цена за единицу", value: $unitCost, format: .number).keyboardType(.decimalPad)
                TextField("Отход, %", value: $waste, format: .number).keyboardType(.decimalPad)
            }
            .navigationTitle("Добавить затрату").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        let line = CostLine(title: title.isEmpty ? category.rawValue : title, category: category, quantity: max(0, qty), unit: unit, unitCost: max(0, unitCost), wastePercent: max(0, waste), order: order)
                        context.insert(line); order.costLines.append(line); try? context.save(); dismiss()
                    }
                }
            }
        }.tint(CF.red)
    }
}

// MARK: - Calculator

enum LetterTariff: String, CaseIterable, Identifiable {
    case volumetricLit = "Объёмные световые"
    case volumetricUnlit = "Объёмные несветовые"
    case halo = "Контражурные"
    case pvc = "Плоские ПВХ"
    case acrylic = "Акриловые"
    case neon = "Неоновые"
    case metal = "Металлические"
    case custom = "Другой тип"
    var id: String { rawValue }
}

enum CalculatorProduct: String, CaseIterable, Identifiable {
    case letters = "Буквы"
    case banner = "Баннер"
    case lightbox = "Световой короб"
    case alucobond = "Фон из алюкобонда"
    case pvc = "Фон из ПВХ"
    case perforated = "Перфоплёнка"
    case vinyl = "Винил"
    case oracal = "Оракал"

    var id: String { rawValue }
    var isLetters: Bool { self == .letters }

    var productType: ProductType {
        switch self {
        case .letters: .letters
        case .banner: .banner
        case .lightbox: .lightbox
        case .alucobond: .alucobond
        case .pvc: .pvcBackground
        case .perforated: .perforated
        case .vinyl: .vinylMaterial
        case .oracal: .oracal
        }
    }
}

struct CalculatorView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AdOrder.number, order: .reverse) private var orders: [AdOrder]

    @AppStorage("cf.rate.volLit") private var volLit = 500.0
    @AppStorage("cf.rate.volUnlit") private var volUnlit = 300.0
    @AppStorage("cf.rate.halo") private var halo = 650.0
    @AppStorage("cf.rate.pvcLetters") private var pvcLetters = 180.0
    @AppStorage("cf.rate.acrylic") private var acrylic = 350.0
    @AppStorage("cf.rate.neon") private var neon = 600.0
    @AppStorage("cf.rate.metal") private var metal = 700.0
    @AppStorage("cf.rate.customLetters") private var customLetters = 500.0

    @AppStorage("cf.rate.bannerM2") private var bannerRate = 0.0
    @AppStorage("cf.rate.lightboxM2") private var lightboxRate = 0.0
    @AppStorage("cf.rate.alucobondM2") private var alucobondRate = 0.0
    @AppStorage("cf.rate.pvcBackgroundM2") private var pvcBackgroundRate = 0.0
    @AppStorage("cf.rate.perforatedM2") private var perforatedRate = 0.0
    @AppStorage("cf.rate.vinylM2") private var vinylRate = 0.0
    @AppStorage("cf.rate.oracalM2") private var oracalRate = 0.0

    @State private var product: CalculatorProduct = .letters

    // Letters
    @State private var text = "COLORIZE"
    @State private var heightCM = 60.0
    @State private var autoCount = true
    @State private var manualCount = 8
    @State private var letterType: LetterTariff = .volumetricLit

    // Area products
    @State private var widthM = 1.0
    @State private var heightM = 1.0
    @State private var quantity = 1

    // Extras
    @State private var backing = 0.0
    @State private var installation = 0.0
    @State private var delivery = 0.0
    @State private var lift = 0.0
    @State private var other = 0.0
    @State private var created: Int?

    private var countFromText: Int { text.filter { $0.isLetter || $0.isNumber }.count }
    private var letterCount: Int { autoCount ? countFromText : max(0, manualCount) }

    private var letterRate: Double {
        switch letterType {
        case .volumetricLit: volLit
        case .volumetricUnlit: volUnlit
        case .halo: halo
        case .pvc: pvcLetters
        case .acrylic: acrylic
        case .neon: neon
        case .metal: metal
        case .custom: customLetters
        }
    }

    private var letterRateBinding: Binding<Double> {
        Binding(get: { letterRate }, set: { value in
            let safe = max(0, value)
            switch letterType {
            case .volumetricLit: volLit = safe
            case .volumetricUnlit: volUnlit = safe
            case .halo: halo = safe
            case .pvc: pvcLetters = safe
            case .acrylic: acrylic = safe
            case .neon: neon = safe
            case .metal: metal = safe
            case .custom: customLetters = safe
            }
        })
    }

    private var areaRate: Double {
        switch product {
        case .letters: 0
        case .banner: bannerRate
        case .lightbox: lightboxRate
        case .alucobond: alucobondRate
        case .pvc: pvcBackgroundRate
        case .perforated: perforatedRate
        case .vinyl: vinylRate
        case .oracal: oracalRate
        }
    }

    private var areaRateBinding: Binding<Double> {
        Binding(get: { areaRate }, set: { value in
            let safe = max(0, value)
            switch product {
            case .letters: break
            case .banner: bannerRate = safe
            case .lightbox: lightboxRate = safe
            case .alucobond: alucobondRate = safe
            case .pvc: pvcBackgroundRate = safe
            case .perforated: perforatedRate = safe
            case .vinyl: vinylRate = safe
            case .oracal: oracalRate = safe
            }
        })
    }

    private var oneLetter: Double { max(0, heightCM) * max(0, letterRate) }
    private var lettersPrice: Double { oneLetter * Double(letterCount) }

    private var areaOne: Double { max(0, widthM) * max(0, heightM) }
    private var totalArea: Double { areaOne * Double(max(1, quantity)) }
    private var areaPrice: Double { totalArea * max(0, areaRate) }

    private var basePrice: Double { product.isLetters ? lettersPrice : areaPrice }
    private var extras: Double { max(0, backing) + max(0, installation) + max(0, delivery) + max(0, lift) + max(0, other) }
    private var total: Double { basePrice + extras }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 14) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Калькулятор заказа").font(.title3.bold())
                            Picker("Тип расчёта", selection: $product) {
                                ForEach(CalculatorProduct.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.menu)

                            Text(product.isLetters
                                 ? "Буквы считаются только по количеству, высоте одной буквы и цене за 1 см. Ширина не используется."
                                 : "Расчёт по площади: ширина × высота × количество × цена за 1 м².")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if product.isLetters {
                        letterCard
                    } else {
                        areaCard
                    }

                    extrasCard
                    resultCard
                    createOrderButton
                    tariffsCard
                }
                .padding(16)
                .padding(.bottom, 20)
            }
        }
        .navigationTitle("Калькулятор")
        .alert("Заказ создан", isPresented: Binding(
            get: { created != nil },
            set: { if !$0 { created = nil } }
        )) {
            Button("Готово", role: .cancel) {}
        } message: {
            if let created { Text("Расчёт сохранён как заказ №\(created).") }
        }
    }

    private var letterCard: some View {
        GlassCard {
            VStack(spacing: 13) {
                TextField("Надпись, например STATUS TEAM", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()

                Picker("Тип букв", selection: $letterType) {
                    ForEach(LetterTariff.allCases) { Text($0.rawValue).tag($0) }
                }

                HStack(spacing: 10) {
                    field("Высота одной буквы, см", $heightCM)
                    field("Цена за 1 см, ₸", letterRateBinding)
                }

                Toggle("Считать буквы из текста", isOn: $autoCount)
                if autoCount {
                    valueRow("Количество букв", "\(letterCount)")
                } else {
                    Stepper("Количество букв: \(manualCount)", value: $manualCount, in: 0...200)
                }
            }
        }
    }

    private var areaCard: some View {
        GlassCard {
            VStack(spacing: 13) {
                HStack(spacing: 10) {
                    field("Ширина, м", $widthM)
                    field("Высота, м", $heightM)
                }

                HStack {
                    Text("Количество").foregroundStyle(.secondary)
                    Spacer()
                    Stepper("\(quantity) шт.", value: $quantity, in: 1...500)
                        .fixedSize()
                }

                field("Цена за 1 м², ₸", areaRateBinding)
                valueRow("Площадь 1 шт.", "\(CF.number(areaOne)) м²")
                valueRow("Общая площадь", "\(CF.number(totalArea)) м²")
            }
        }
    }

    private var extrasCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                Text("Дополнительно").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                if product.isLetters {
                    moneyRow("Подложка", $backing)
                }
                moneyRow("Монтаж", $installation)
                moneyRow("Доставка", $delivery)
                moneyRow("Автовышка", $lift)
                moneyRow("Другие расходы", $other)
            }
        }
    }

    private var resultCard: some View {
        GlassCard {
            VStack(spacing: 10) {
                if product.isLetters {
                    valueRow("Тип букв", letterType.rawValue)
                    valueRow("Одна буква", CF.money(oneLetter))
                    valueRow("Все буквы (\(letterCount) шт.)", CF.money(lettersPrice))
                    Text("\(letterCount) × \(CF.number(heightCM)) см × \(CF.money(letterRate))/см")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    valueRow("Изделие", product.rawValue)
                    valueRow("Общая площадь", "\(CF.number(totalArea)) м²")
                    valueRow("Стоимость по площади", CF.money(areaPrice))
                    Text("\(CF.number(widthM)) × \(CF.number(heightM)) м × \(quantity) × \(CF.money(areaRate))/м²")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if extras > 0 { valueRow("Дополнительно", CF.money(extras)) }
                Divider()
                HStack {
                    Text("Итого клиенту").font(.headline)
                    Spacer()
                    Text(CF.money(total))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(CF.red)
                }
            }
        }
    }

    private var createOrderButton: some View {
        Button {
            createOrder()
        } label: {
            Label("Создать заказ из расчёта", systemImage: "doc.badge.plus")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .fontWeight(.bold)
        }
        .buttonStyle(.borderedProminent)
        .tint(CF.red)
        .disabled(total <= 0 || (product.isLetters && letterCount <= 0))
    }

    private var tariffsCard: some View {
        GlassCard {
            VStack(spacing: 9) {
                Text("Тарифы").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                Text("Тарифы сохраняются на телефоне и подставляются автоматически.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                tariff("Буквы · объёмные световые", $volLit, suffix: "₸/см")
                tariff("Буквы · объёмные несветовые", $volUnlit, suffix: "₸/см")
                tariff("Буквы · контражурные", $halo, suffix: "₸/см")
                tariff("Буквы · плоские ПВХ", $pvcLetters, suffix: "₸/см")
                tariff("Буквы · акриловые", $acrylic, suffix: "₸/см")
                tariff("Буквы · неоновые", $neon, suffix: "₸/см")
                tariff("Буквы · металлические", $metal, suffix: "₸/см")
                tariff("Буквы · другой тип", $customLetters, suffix: "₸/см")
                Divider()
                tariff("Баннер", $bannerRate, suffix: "₸/м²")
                tariff("Световой короб", $lightboxRate, suffix: "₸/м²")
                tariff("Фон из алюкобонда", $alucobondRate, suffix: "₸/м²")
                tariff("Фон из ПВХ", $pvcBackgroundRate, suffix: "₸/м²")
                tariff("Перфоплёнка", $perforatedRate, suffix: "₸/м²")
                tariff("Винил", $vinylRate, suffix: "₸/м²")
                tariff("Оракал", $oracalRate, suffix: "₸/м²")
            }
        }
    }

    private func field(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func moneyRow(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 130)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).bold().multilineTextAlignment(.trailing)
        }
    }

    private func tariff(_ title: String, _ value: Binding<Double>, suffix: String) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 95)
                .textFieldStyle(.roundedBorder)
            Text(suffix).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func createOrder() {
        let next = (orders.first?.number ?? 0) + 1
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let title: String
        let notes: String
        let width: Double
        let height: Double

        if product.isLetters {
            title = cleanText.isEmpty ? "Буквы" : cleanText
            width = 0
            height = max(0, heightCM) / 100
            notes = """
            Калькулятор заказа
            Изделие: Буквы
            Тип букв: \(letterType.rawValue)
            Надпись: \(cleanText)
            Количество букв: \(letterCount)
            Высота одной буквы: \(CF.number(heightCM)) см
            Тариф: \(CF.money(letterRate))/см
            Стоимость букв: \(CF.money(lettersPrice))
            Подложка: \(CF.money(backing))
            Монтаж: \(CF.money(installation))
            Доставка: \(CF.money(delivery))
            Автовышка: \(CF.money(lift))
            Другие расходы: \(CF.money(other))
            Итого: \(CF.money(total))
            """
        } else {
            title = product.rawValue
            width = max(0, widthM)
            height = max(0, heightM)
            notes = """
            Калькулятор заказа
            Изделие: \(product.rawValue)
            Размер одного изделия: \(CF.number(widthM)) × \(CF.number(heightM)) м
            Количество: \(quantity)
            Общая площадь: \(CF.number(totalArea)) м²
            Тариф: \(CF.money(areaRate))/м²
            Стоимость по площади: \(CF.money(areaPrice))
            Монтаж: \(CF.money(installation))
            Доставка: \(CF.money(delivery))
            Автовышка: \(CF.money(lift))
            Другие расходы: \(CF.money(other))
            Итого: \(CF.money(total))
            """
        }

        let order = AdOrder(
            number: next,
            title: title,
            productType: product.productType,
            widthMeters: width,
            heightMeters: height,
            salePrice: total,
            notes: notes
        )
        context.insert(order)
        try? context.save()
        created = next
    }
}

// MARK: - Materials

struct MaterialsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Material.name) private var materials: [Material]
    @State private var showingAdd = false
    @State private var search = ""

    var body: some View {
        ZStack {
            AppBackground()
            if materials.isEmpty {
                ContentUnavailableView("Нет материалов", systemImage: "shippingbox", description: Text("Добавьте материалы и закупочные цены."))
            } else {
                List {
                    ForEach(materials.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) }) { m in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(m.name).font(.headline)
                                Text("\(m.category) · \(m.unitRaw) · отход \(CF.number(m.defaultWastePercent))%").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(CF.money(m.purchasePrice)).bold()
                        }.listRowBackground(Color.clear)
                    }
                    .onDelete { offsets in
                        let list = materials.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) }
                        for i in offsets { context.delete(list[i]) }
                        try? context.save()
                    }
                }.scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Материалы")
        .searchable(text: $search)
        .toolbar { Button { showingAdd = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $showingAdd) { AddMaterialView() }
    }
}

struct AddMaterialView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var category = "Общее"
    @State private var unit: MaterialUnit = .squareMeter
    @State private var price = 0.0
    @State private var waste = 10.0
    @State private var stock = 0.0
    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $name)
                TextField("Категория", text: $category)
                Picker("Единица", selection: $unit) { ForEach(MaterialUnit.allCases) { Text($0.rawValue).tag($0) } }
                TextField("Закупочная цена", value: $price, format: .number).keyboardType(.decimalPad)
                TextField("Отход, %", value: $waste, format: .number).keyboardType(.decimalPad)
                TextField("Остаток", value: $stock, format: .number).keyboardType(.decimalPad)
            }
            .navigationTitle("Новый материал").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        context.insert(Material(name: name.isEmpty ? "Материал" : name, category: category, unit: unit, purchasePrice: max(0, price), defaultWastePercent: max(0, waste), stockQuantity: max(0, stock)))
                        try? context.save(); dismiss()
                    }
                }
            }
        }.tint(CF.red)
    }
}

// MARK: - More / Analytics / Expenses / Clients / Settings

struct MoreView: View {
    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 12) {
                    moreLink("Аналитика", "Выручка, себестоимость и прибыль", "chart.bar.fill") { AnalyticsView() }
                    moreLink("Расходы", "Общие расходы компании", "creditcard.fill") { ExpensesView() }
                    moreLink("Клиенты", "База клиентов", "person.2.fill") { ClientsView() }
                    moreLink("Настройки", "Версия приложения", "gearshape.fill") { SettingsView() }
                }.padding(16)
            }
        }.navigationTitle("Ещё")
    }
    private func moreLink<D: View>(_ title: String, _ subtitle: String, _ icon: String, @ViewBuilder destination: () -> D) -> some View {
        NavigationLink(destination: destination()) {
            GlassCard {
                HStack(spacing: 13) {
                    Image(systemName: icon).foregroundStyle(CF.red).frame(width: 42, height: 42).background(CF.red.opacity(0.1), in: Circle())
                    VStack(alignment: .leading) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
        }.buttonStyle(.plain)
    }
}

struct AnalyticsView: View {
    @Query private var orders: [AdOrder]
    @Query private var expenses: [CompanyExpense]
    var body: some View {
        let revenue = orders.reduce(0) { $0 + $1.salePrice }
        let costs = orders.reduce(0) { $0 + $1.totalCost }
        let overhead = expenses.reduce(0) { $0 + $1.amount }
        let profit = revenue - costs - overhead
        return ZStack {
            AppBackground()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetricCard(title: "Выручка", value: CF.money(revenue), icon: "banknote.fill")
                    MetricCard(title: "Себестоимость", value: CF.money(costs), icon: "hammer.fill")
                    MetricCard(title: "Общие расходы", value: CF.money(overhead), icon: "creditcard.fill")
                    MetricCard(title: "Чистая прибыль", value: CF.money(profit), icon: "chart.line.uptrend.xyaxis")
                }.padding(16)
            }
        }.navigationTitle("Аналитика")
    }
}

struct ExpensesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CompanyExpense.date, order: .reverse) private var expenses: [CompanyExpense]
    @State private var showAdd = false
    var body: some View {
        ZStack {
            AppBackground()
            List {
                Section {
                    GlassCard {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Расходы за текущий месяц").font(.caption).foregroundStyle(.secondary)
                                Text(CF.money(monthTotal)).font(.title2.bold())
                            }
                            Spacer(); Image(systemName: "creditcard.fill").foregroundStyle(CF.red).font(.title2)
                        }
                    }.listRowBackground(Color.clear)
                }
                ForEach(expenses) { e in
                    HStack {
                        VStack(alignment: .leading) { Text(e.title).font(.headline); Text(e.category).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Text(CF.money(e.amount)).bold()
                    }.listRowBackground(Color.clear)
                }.onDelete { offsets in
                    for i in offsets { context.delete(expenses[i]) }
                    try? context.save()
                }
            }.scrollContentBackground(.hidden)
        }
        .navigationTitle("Расходы")
        .toolbar { Button { showAdd = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $showAdd) { AddExpenseView() }
    }
    private var monthTotal: Double {
        let interval = Calendar.current.dateInterval(of: .month, for: .now)
        return expenses.filter { interval?.contains($0.date) == true }.reduce(0) { $0 + $1.amount }
    }
}

struct AddExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var title = ""
    @State private var category = "Прочее"
    @State private var amount = 0.0
    @State private var notes = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $title)
                TextField("Категория", text: $category)
                TextField("Сумма", value: $amount, format: .number).keyboardType(.decimalPad)
                TextField("Заметка", text: $notes, axis: .vertical)
            }
            .navigationTitle("Новый расход").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") { context.insert(CompanyExpense(title: title.isEmpty ? "Расход" : title, category: category, amount: max(0, amount), notes: notes)); try? context.save(); dismiss() }
                }
            }
        }.tint(CF.red)
    }
}

struct ClientsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Client.name) private var clients: [Client]
    @State private var showAdd = false
    var body: some View {
        ZStack {
            AppBackground()
            if clients.isEmpty {
                ContentUnavailableView("Клиентов пока нет", systemImage: "person.2")
            } else {
                List {
                    ForEach(clients) { c in
                        VStack(alignment: .leading) {
                            Text(c.name).font(.headline)
                            if !c.company.isEmpty { Text(c.company).font(.caption).foregroundStyle(.secondary) }
                            if !c.phone.isEmpty { Text(c.phone).font(.caption).foregroundStyle(.secondary) }
                        }.listRowBackground(Color.clear)
                    }.onDelete { offsets in
                        for i in offsets { context.delete(clients[i]) }
                        try? context.save()
                    }
                }.scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Клиенты")
        .toolbar { Button { showAdd = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $showAdd) { AddClientView() }
    }
}

struct AddClientView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var phone = ""
    @State private var company = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Имя / название", text: $name)
                TextField("Компания", text: $company)
                TextField("Телефон", text: $phone).keyboardType(.phonePad)
            }
            .navigationTitle("Новый клиент").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") { context.insert(Client(name: name.isEmpty ? "Клиент" : name, phone: phone, company: company)); try? context.save(); dismiss() }
                }
            }
        }.tint(CF.red)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthController
    @EnvironmentObject private var sync: CloudSyncCoordinator

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 14) {
                    GlassCard {
                        VStack(spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(auth.session?.email ?? "Аккаунт").font(.headline)
                                    Text("Firebase аккаунт Colorize Finance").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "person.crop.circle.fill").font(.title).foregroundStyle(CF.red)
                            }
                            Divider()
                            syncStatus
                            Button {
                                Task { await sync.syncNow(auth: auth) }
                            } label: {
                                Label("Синхронизировать сейчас", systemImage: "arrow.triangle.2.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                auth.signOut()
                            } label: {
                                Label("Выйти из аккаунта", systemImage: "rectangle.portrait.and.arrow.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    GlassCard {
                        VStack(spacing: 12) {
                            HStack { Text("Название").foregroundStyle(.secondary); Spacer(); Text("Colorize Finance").bold() }
                            Divider()
                            HStack { Text("Версия").foregroundStyle(.secondary); Spacer(); Text("3.2.0").bold() }
                            Divider()
                            HStack { Text("Build").foregroundStyle(.secondary); Spacer(); Text("9").bold() }
                            Divider()
                            HStack { Text("Минимальная система").foregroundStyle(.secondary); Spacer(); Text("iOS / iPadOS 17").bold() }
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Калькулятор заказов").font(.headline)
                            Text("Буквы рассчитываются по количеству × высоте × цене за сантиметр. Баннер, световой короб, алюкобонд, ПВХ, перфоплёнка, винил и оракал — по площади и тарифу за м².")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Настройки")
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch sync.state {
        case .idle:
            HStack { Text("Синхронизация").foregroundStyle(.secondary); Spacer(); Text("Готово").foregroundStyle(.green) }
        case .syncing:
            HStack { Text("Синхронизация").foregroundStyle(.secondary); Spacer(); ProgressView() }
        case .success(let date):
            HStack { Text("Последняя синхронизация").foregroundStyle(.secondary); Spacer(); Text(date.formatted(date: .omitted, time: .shortened)).foregroundStyle(.green) }
        case .failed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Text("Ошибка синхронизации").foregroundStyle(.red)
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

