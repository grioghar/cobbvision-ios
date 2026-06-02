import SwiftUI
import MapKit

struct SessionView: View {
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var sessionStore:    SessionStore

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.01),
        span:   MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
    )
    @State private var showPermissionAlert = false
    @State private var finishedSession:     DriveSession?

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {

                // Live map
                Map(coordinateRegion: $region,
                    showsUserLocation: true,
                    userTrackingMode: .constant(.follow))
                    .ignoresSafeArea(edges: .top)
                    .onChange(of: locationManager.currentLocation) { loc in
                        if let loc {
                            region.center = loc.coordinate
                        }
                    }

                // HUD overlay
                VStack(spacing: 0) {
                    if locationManager.isRecording,
                       let session = locationManager.currentSession {
                        RecordingHUD(session: session)
                    }

                    RecordButton(isRecording: locationManager.isRecording) {
                        if locationManager.isRecording {
                            if let finished = locationManager.stopRecording() {
                                sessionStore.save(session: finished)
                                finishedSession = finished
                            }
                        } else {
                            if locationManager.authorizationStatus == .notDetermined {
                                locationManager.requestPermission()
                            } else if locationManager.authorizationStatus == .denied ||
                                      locationManager.authorizationStatus == .restricted {
                                showPermissionAlert = true
                            } else {
                                locationManager.startRecording()
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("CobbVision")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Location Access Required",
                   isPresented: $showPermissionAlert) {
                Button("Open Settings") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Please enable location access in Settings so CobbVision can record your GPS track.")
            }
            .sheet(item: $finishedSession) { session in
                UploadSheet(session: session)
                    .environmentObject(sessionStore)
            }
        }
    }
}

// MARK: - Sub-components

private struct RecordingHUD: View {
    let session: DriveSession

    var body: some View {
        HStack(spacing: 24) {
            VStack {
                Text(durationString(session.duration))
                    .font(.system(.title2, design: .monospaced))
                    .foregroundColor(.white)
                Text("Duration").font(.caption).foregroundColor(.gray)
            }
            Divider().frame(height: 40).background(Color.gray)
            VStack {
                Text("\(session.pointCount)")
                    .font(.system(.title2, design: .monospaced))
                    .foregroundColor(.white)
                Text("Points").font(.caption).foregroundColor(.gray)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.bottom, 12)
    }

    private func durationString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.orange)
                    .frame(width: 72, height: 72)
                    .shadow(radius: 8)
                if isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 36, height: 36)
                }
            }
        }
    }
}
