import SwiftUI
import ImageAssetManagerCore

struct DateRangePickerView: View {
    @Bindable var viewModel: SpendViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(SpendViewModel.DateRangePreset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) {
                        viewModel.selectedPreset = preset
                    }
                    .buttonStyle(DateChipButtonStyle(isSelected: viewModel.selectedPreset == preset))
                }
            }

            if viewModel.selectedPreset == .custom {
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Text("From")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                        DatePicker("", selection: $viewModel.customStartDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                    }
                    HStack(spacing: 6) {
                        Text("To")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                        DatePicker(
                            "",
                            selection: $viewModel.customEndDate,
                            in: viewModel.customStartDate...,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.compact)
                        .labelsHidden()
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.selectedPreset)
    }
}

private struct DateChipButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.appAccent : Color.appSurfaceRaised, in: Capsule())
            .foregroundStyle(isSelected ? Color.white : Color.appTextPrimary)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}
