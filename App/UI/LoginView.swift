import SwiftUI
import CVAPI

struct LoginView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    VStack(spacing: 8) {
                        Image(systemName: "gauge.open.with.lines.needle.67percent.and.arrowtriangle")
                            .font(.system(size: 40))
                        Text("Sign in with your CobbVision account")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if busy {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Sign In").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                } footer: {
                    Text("No account yet? Create one at cobbvision.grio.co first.")
                }
            }
            .navigationTitle("CobbVision")
        }
    }

    private func submit() async {
        busy = true
        errorMessage = nil
        do {
            try await env.login(email: email, password: password)
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
        busy = false
    }
}
