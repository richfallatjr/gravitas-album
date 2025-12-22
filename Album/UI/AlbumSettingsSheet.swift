import SwiftUI

public struct AlbumSettingsSheet: View {
    @EnvironmentObject private var model: AlbumModel
    @Environment(\.dismiss) private var dismiss

    @State private var isUnhidingAll: Bool = false
    @State private var unhideAllMessage: String? = nil

    public init() {}

    public var body: some View {
        let palette = model.palette
        let status = model.backfillStatus
        let total = max(0, status.totalAssets)
        let computed = max(0, status.computed)
        let computedPercent = total > 0 ? Int((Double(computed) / Double(total) * 100).rounded()) : 0

        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text("Settings")
                    .font(.title3.weight(.semibold))

                Spacer(minLength: 0)

                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .tint(palette.historyButtonColor)
                    .foregroundStyle(palette.buttonLabelOnColor)
            }

            GroupBox {
                let coverage = model.visionCoverage
                let totalAssets = max(0, coverage.totalAssets)

                let labeled = max(0, coverage.computed + coverage.autofilled)
                let labeledPercent = totalAssets > 0
                    ? Int((Double(labeled) / Double(totalAssets) * 100).rounded())
                    : 0

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("Vision Coverage")
                            .font(.headline)

                        Spacer(minLength: 0)

                        Button(model.visionCoverageIsRefreshing ? "Calculating…" : "Recalculate") {
                            model.refreshVisionCoverage()
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.copyButtonFill)
                        .foregroundStyle(palette.buttonLabelOnColor)
                        .disabled(model.visionCoverageIsRefreshing)

                        if model.visionCoverageIsRefreshing {
                            ProgressView()
                        }
                    }

                    if totalAssets > 0, coverage.updatedAt != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("Computed \(coverage.computedPercent)%")
                                    .font(.title3.weight(.semibold))

                                Text("Labeled \(labeledPercent)%")
                                    .font(.caption)
                                    .foregroundStyle(palette.panelSecondaryText)
                            }

                            ProgressView(value: Double(coverage.computed), total: Double(totalAssets))
                                .progressViewStyle(.linear)
                                .tint(palette.copyButtonFill)

                            Text("Computed \(coverage.computed)/\(totalAssets) • Autofilled \(coverage.autofilled) • Missing \(coverage.missing) • Failed \(coverage.failed)")
                                .font(.caption2)
                                .foregroundStyle(palette.panelSecondaryText)
                        }
                    } else {
                        Text("Tap Recalculate to scan sidecars and compute Vision coverage for your full library.")
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                    }

                    if let err = coverage.lastError, !err.isEmpty {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                            .lineLimit(2)
                    }
                }
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Indexing")
                        .font(.headline)

                    if total > 0 {
                        ProgressView(value: Double(computed), total: Double(total))
                            .progressViewStyle(.linear)
                            .tint(palette.copyButtonFill)

                        Text("Computed \(computed)/\(total) (\(computedPercent)%) • Autofilled \(status.autofilled) • Missing \(status.missing) • Failed \(status.failed)")
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                    } else {
                        Text("Indexing is unavailable until Photos access is granted.")
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                    }

                    if let err = status.lastError, !err.isEmpty {
                        Text("Last error: \(err)")
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                            .lineLimit(2)
                    }

                    HStack(spacing: 10) {
                        Button(status.paused ? "Resume" : "Pause") {
                            if status.paused {
                                model.resumeBackfill()
                            } else {
                                model.pauseBackfill()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.historyButtonColor)
                        .foregroundStyle(palette.buttonLabelOnColor)

                        Button("Restart Indexing") {
                            model.restartIndexing()
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.copyButtonFill)
                        .foregroundStyle(palette.buttonLabelOnColor)

                        Button("Retry Failed") {
                            model.retryFailedBackfill()
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.historyButtonColor)
                        .foregroundStyle(palette.buttonLabelOnColor)
                        .disabled(status.failed <= 0)

                        Button("Apply Autofill") {
                            model.applySeedAutofillPass()
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.copyButtonFill)
                        .foregroundStyle(palette.buttonLabelOnColor)

                        Spacer(minLength: 0)

                        Text(status.paused ? "Paused" : (status.running ? "Running" : "Idle"))
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                    }

                    HStack(spacing: 10) {
                        Button(isUnhidingAll ? "Unhiding…" : "Unhide All") {
                            Task {
                                isUnhidingAll = true
                                let changed = await model.unhideAllAssets()
                                isUnhidingAll = false
                                unhideAllMessage = changed > 0 ? "Unhid \(changed) items." : "No hidden items found."
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.historyButtonColor)
                        .foregroundStyle(palette.buttonLabelOnColor)
                        .disabled(isUnhidingAll)

                        if isUnhidingAll {
                            ProgressView()
                        }

                        Spacer(minLength: 0)
                    }

                    if let unhideAllMessage, !unhideAllMessage.isEmpty {
                        Text(unhideAllMessage)
                            .font(.caption2)
                            .foregroundStyle(palette.panelSecondaryText)
                            .lineLimit(2)
                    }
                }
                .padding(8)
            }

#if DEBUG
	            GroupBox {
	                VStack(alignment: .leading, spacing: 10) {
	                    Text("Developer")
	                        .font(.headline)

	                    Toggle("Show Faces Button", isOn: $model.settings.showFacesDebugUI)
	                        .toggleStyle(.switch)

	                    Toggle("Thumb-Up Neighbor Autofill", isOn: $model.settings.autofillOnThumbUp)
	                        .toggleStyle(.switch)

	                    Text("Uses 5 neighbors and only overwrites autofilled items.")
	                        .font(.caption2)
	                        .foregroundStyle(palette.panelSecondaryText)
	                }
	                .padding(8)
	            }
#endif

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(palette.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(palette.cardBorder.opacity(0.75), lineWidth: 1)
        )
        .onAppear {
            if model.visionCoverage.updatedAt == nil, !model.visionCoverageIsRefreshing {
                model.refreshVisionCoverage()
            }
        }
        .preferredColorScheme(model.theme == .dark ? .dark : .light)
        .foregroundStyle(palette.panelPrimaryText)
    }
}
