import SwiftUI

/// Country selection for the New page's Apple Podcasts charts. By default the storefront follows
/// the Mac's detected country; an explicit choice persists until Use Location is selected again.
struct NewCountryPicker: View {
    @State private var showingCountries = false
    @State private var search = ""

    private var store: DiscoveryStore { .shared }

    private struct Country: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    private static let countries: [Country] = Locale.Region.isoRegions.compactMap { region in
        let code = region.identifier.lowercased()
        guard code.count == 2, code.allSatisfy(\.isLetter) else { return nil }
        return Country(code: code, name: name(for: code))
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    private static func name(for code: String) -> String {
        Locale.current.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }

    private var detectedName: String { Self.name(for: store.detectedCountry) }
    private var selectedName: String {
        store.countryOverride.map { Self.name(for: $0) } ?? "Use Location · \(detectedName)"
    }
    private var filteredCountries: [Country] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return Self.countries }
        return Self.countries.filter { $0.name.localizedStandardContains(term) || $0.code.localizedStandardContains(term) }
    }

    var body: some View {
        Button {
            search = ""
            showingCountries = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                Text(selectedName).font(.callout.weight(.medium)).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose a country for the New page’s podcast charts")
        .popover(isPresented: $showingCountries, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Podcast Charts Country").font(.headline)
                Button { select(nil) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "location.fill")
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        Text("Use Location · \(detectedName)").font(.callout.weight(.medium))
                        Spacer()
                        if store.countryOverride == nil {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                Divider()
                TextField("Search countries", text: $search)
                    .textFieldStyle(.roundedBorder)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredCountries) { country in
                            Button { select(country.code) } label: {
                                HStack(spacing: 10) {
                                    Text(country.name).font(.callout)
                                    Spacer()
                                    if store.countryOverride == country.code {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 290)
            }
            .padding(16)
            .frame(width: 340)
        }
    }

    private func select(_ code: String?) {
        showingCountries = false
        store.selectCountry(code)
    }
}
