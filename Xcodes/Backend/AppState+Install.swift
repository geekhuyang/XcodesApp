import Combine
import Foundation
import Path
import AppleAPI
import Version
import LegibleError
import os.log

/// Downloads and installs Xcodes
extension AppState {
    public func install(_ installationType: InstallationType, downloader: Downloader) -> AnyPublisher<Void, Error> {
        install(installationType, downloader: downloader, attemptNumber: 0)
            .map { _ in Void() }
            .eraseToAnyPublisher()
    }
    
    private func install(_ installationType: InstallationType, downloader: Downloader, attemptNumber: Int) -> AnyPublisher<InstalledXcode, Error> {
        getXcodeArchive(installationType, downloader: downloader)
            .flatMap { xcode, url -> AnyPublisher<InstalledXcode, Swift.Error> in
                self.installArchivedXcode(xcode, at: url)
            }
            .catch { error -> AnyPublisher<InstalledXcode, Swift.Error> in
                switch error {
                case InstallationError.damagedXIP(let damagedXIPURL):
                    guard attemptNumber < 1 else { return Fail(error: error).eraseToAnyPublisher() }

                    switch installationType {
                    case .version:
                        // If the XIP was just downloaded, remove it and try to recover.
                        do {
                            Logger.appState.error("\(error.legibleLocalizedDescription)")
                            Logger.appState.info("Removing damaged XIP and re-attempting installation.")
                            try Current.files.removeItem(at: damagedXIPURL)
                            return self.install(installationType, downloader: downloader, attemptNumber: attemptNumber + 1)
                                .eraseToAnyPublisher()
                        } catch {
                            return Fail(error: error)
                                .eraseToAnyPublisher()
                        }
                    }
                default:
                    return Fail(error: error)
                        .eraseToAnyPublisher()
                }
            }
            .handleEvents(receiveOutput: { installedXcode in
                DispatchQueue.main.async {
                    guard let index = self.allXcodes.firstIndex(where: { $0.version.isEquivalent(to: installedXcode.version) }) else { return }
                    self.allXcodes[index].installState = .installed(installedXcode.path)
                }
            })
            .eraseToAnyPublisher()
    }
    
    private func getXcodeArchive(_ installationType: InstallationType, downloader: Downloader) -> AnyPublisher<(AvailableXcode, URL), Error> {
        switch installationType {
        case .version(let availableXcode):
            if let installedXcode = Current.files.installedXcodes(Path.root/"Applications").first(where: { $0.version.isEquivalent(to: availableXcode.version) }) {
                return Fail(error: InstallationError.versionAlreadyInstalled(installedXcode))
                    .eraseToAnyPublisher()
            }
            return downloadXcode(availableXcode: availableXcode, downloader: downloader)
        }
    }

    private func downloadXcode(availableXcode: AvailableXcode, downloader: Downloader) -> AnyPublisher<(AvailableXcode, URL), Error> {
        downloadOrUseExistingArchive(for: availableXcode, downloader: downloader, progressChanged: { [unowned self] progress in
            DispatchQueue.main.async {
                self.setInstallationStep(of: availableXcode.version, to: .downloading(progress: progress))
            }
        })
        .map { return (availableXcode, $0) }
        .eraseToAnyPublisher()
    }
    
    public func downloadOrUseExistingArchive(for availableXcode: AvailableXcode, downloader: Downloader, progressChanged: @escaping (DownloadProgress) -> Void) -> AnyPublisher<URL, Error> {
        // Check to see if the archive is in the expected path in case it was downloaded but failed to install
        let expectedArchivePath = Path.xcodesApplicationSupport/"Xcode-\(availableXcode.version).\(availableXcode.filename.suffix(fromLast: "."))"
        // aria2 downloads directly to the destination (instead of into /tmp first) so we need to make sure that the download isn't incomplete
        let aria2DownloadMetadataPath = expectedArchivePath.parent/(expectedArchivePath.basename() + ".aria2")
        var aria2DownloadIsIncomplete = false
        if case .aria2 = downloader, aria2DownloadMetadataPath.exists {
            aria2DownloadIsIncomplete = true
        }
        if Current.files.fileExistsAtPath(expectedArchivePath.string), aria2DownloadIsIncomplete == false {
            Logger.appState.info("Found existing archive that will be used for installation at \(expectedArchivePath).")
            return Just(expectedArchivePath.url)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        else {
            let destination = Path.xcodesApplicationSupport/"Xcode-\(availableXcode.version).\(availableXcode.filename.suffix(fromLast: "."))"
            switch downloader {
            case .aria2:
                let aria2Path = Path(url: Bundle.main.url(forAuxiliaryExecutable: "aria2c")!)!
                return downloadXcodeWithAria2(
                    availableXcode,
                    to: destination,
                    aria2Path: aria2Path,
                    progressChanged: progressChanged
                )
            case .urlSession:
                return downloadXcodeWithURLSession(
                    availableXcode,
                    to: destination,
                    progressChanged: progressChanged
                )
            }
        }
    }
    
    public func downloadXcodeWithAria2(_ availableXcode: AvailableXcode, to destination: Path, aria2Path: Path, progressChanged: @escaping (DownloadProgress) -> Void) -> AnyPublisher<URL, Error> {
        let cookies = AppleAPI.Current.network.session.configuration.httpCookieStorage?.cookies(for: availableXcode.url) ?? []
    
        let (progress, publisher) = Current.shell.downloadWithAria2(
            aria2Path, 
            availableXcode.url,
            destination,
            cookies
        )
        progressChanged(progress)
        return publisher
            .map { _ in destination.url }
            .eraseToAnyPublisher()
    }

    public func downloadXcodeWithURLSession(_ availableXcode: AvailableXcode, to destination: Path, progressChanged: @escaping (DownloadProgress) -> Void) -> AnyPublisher<URL, Error> {
        let resumeDataPath = Path.xcodesApplicationSupport/"Xcode-\(availableXcode.version).resumedata"
        let persistedResumeData = Current.files.contents(atPath: resumeDataPath.string)
        
        return attemptResumableTask(maximumRetryCount: 3) { resumeData -> AnyPublisher<URL, Error> in
            let (progress, publisher) = Current.network.downloadTask(with: availableXcode.url,
                                                                   to: destination.url,
                                                                   resumingWith: resumeData ?? persistedResumeData)
            progressChanged(DownloadProgress(progress: progress))
            return publisher
                .map { $0.saveLocation }
                .eraseToAnyPublisher()
        }
        .handleEvents(receiveCompletion: { completion in
            self.persistOrCleanUpResumeData(at: resumeDataPath, for: completion)
        })
        .eraseToAnyPublisher()
    }

    public func installArchivedXcode(_ availableXcode: AvailableXcode, at archiveURL: URL) -> AnyPublisher<InstalledXcode, Error> {
        do {
            let destinationURL = Path.root.join("Applications").join("Xcode-\(availableXcode.version.descriptionWithoutBuildMetadata).app").url
            switch archiveURL.pathExtension {
            case "xip":
                return unarchiveAndMoveXIP(availableXcode: availableXcode, at: archiveURL, to: destinationURL)
                    .tryMap { xcodeURL throws -> InstalledXcode in
                        guard 
                            let path = Path(url: xcodeURL),
                            Current.files.fileExists(atPath: path.string),
                            let installedXcode = InstalledXcode(path: path)
                        else { throw InstallationError.failedToMoveXcodeToApplications }
                        return installedXcode
                    }
                    .flatMap { installedXcode -> AnyPublisher<InstalledXcode, Error> in
                        do {
                            self.setInstallationStep(of: availableXcode.version, to: .trashingArchive)
                            try Current.files.trashItem(at: archiveURL)
                            self.setInstallationStep(of: availableXcode.version, to: .checkingSecurity)
                            
                            return self.verifySecurityAssessment(of: installedXcode)
                                .combineLatest(self.verifySigningCertificate(of: installedXcode.path.url))
                                .map { _ in installedXcode }
                                .eraseToAnyPublisher()
                        } catch {
                            return Fail(error: error)
                                .eraseToAnyPublisher()
                        }
                    }
                    .flatMap { installedXcode -> AnyPublisher<InstalledXcode, Error> in
                        self.setInstallationStep(of: availableXcode.version, to: .finishing)

                        return self.performPostInstallSteps(for: installedXcode)
                            .map { installedXcode }
                            // Show post-install errors but don't fail because of them
                            .handleEvents(receiveCompletion: { [unowned self] completion in
                                if case let .failure(error) = completion {
                                    self.error = error
                                }
                            })
                            .catch { _ in
                                Just(installedXcode)
                                    .setFailureType(to: Error.self)
                                    .eraseToAnyPublisher()
                            }
                            .eraseToAnyPublisher()
                    }
                    .eraseToAnyPublisher()
            case "dmg":
                throw InstallationError.unsupportedFileFormat(extension: "dmg")
            default:
                throw InstallationError.unsupportedFileFormat(extension: archiveURL.pathExtension)
            }
        } catch {
            return Fail(error: error)
                .eraseToAnyPublisher()
        }
    }

    func unarchiveAndMoveXIP(availableXcode: AvailableXcode, at source: URL, to destination: URL) -> AnyPublisher<URL, Swift.Error> {
        self.setInstallationStep(of: availableXcode.version, to: .unarchiving)

        return Current.shell.unxip(source)
            .catch { error -> AnyPublisher<ProcessOutput, Swift.Error> in
                if let executionError = error as? ProcessExecutionError {
                   if executionError.standardError.contains("damaged and can’t be expanded") {
                    return Fail(error: InstallationError.damagedXIP(url: source))
                        .eraseToAnyPublisher()
                   } else if executionError.standardError.contains("can’t be expanded because the selected volume doesn’t have enough free space.") {
                    return Fail(error: InstallationError.notEnoughFreeSpaceToExpandArchive(archivePath: Path(url: source)!,
                                                                                           version: availableXcode.version))
                        .eraseToAnyPublisher()
                   }
                }
                return Fail(error: error)
                    .eraseToAnyPublisher()
            }
        .tryMap { output -> URL in
            self.setInstallationStep(of: availableXcode.version, to: .moving(destination: destination.path))

            let xcodeURL = source.deletingLastPathComponent().appendingPathComponent("Xcode.app")
            let xcodeBetaURL = source.deletingLastPathComponent().appendingPathComponent("Xcode-beta.app")
            if Current.files.fileExists(atPath: xcodeURL.path) {
                try Current.files.moveItem(at: xcodeURL, to: destination)
            }
            else if Current.files.fileExists(atPath: xcodeBetaURL.path) {
                try Current.files.moveItem(at: xcodeBetaURL, to: destination)
            }

            return destination
        }
        .handleEvents(receiveCancel: {
            if Current.files.fileExists(atPath: source.path) {
                try? Current.files.removeItem(source)
            }
            if Current.files.fileExists(atPath: destination.path) {
                try? Current.files.removeItem(destination)
            }
        })
        .eraseToAnyPublisher()
    }

    public func verifySecurityAssessment(of xcode: InstalledXcode) -> AnyPublisher<Void, Error> {
        return Current.shell.spctlAssess(xcode.path.url)
            .catch { (error: Swift.Error) -> AnyPublisher<ProcessOutput, Error> in
                var output = ""
                if let executionError = error as? ProcessExecutionError {
                    output = [executionError.standardOutput, executionError.standardError].joined(separator: "\n")
                }
                return Fail(error: InstallationError.failedSecurityAssessment(xcode: xcode, output: output))
                    .eraseToAnyPublisher()
            }
            .map { _ in Void() }
            .eraseToAnyPublisher()
    }

    func verifySigningCertificate(of url: URL) -> AnyPublisher<Void, Error> {
        return Current.shell.codesignVerify(url)
            .catch { error -> AnyPublisher<ProcessOutput, Error> in
                var output = ""
                if let executionError = error as? ProcessExecutionError {
                    output = [executionError.standardOutput, executionError.standardError].joined(separator: "\n")
                }
                return Fail(error: InstallationError.codesignVerifyFailed(output: output))
                    .eraseToAnyPublisher()
            }
            .map { output -> CertificateInfo in
                // codesign prints to stderr
                return self.parseCertificateInfo(output.err)
            }
            .tryMap { cert in
                guard
                    cert.teamIdentifier == XcodeTeamIdentifier,
                    cert.authority == XcodeCertificateAuthority
                else { throw InstallationError.unexpectedCodeSigningIdentity(identifier: cert.teamIdentifier, certificateAuthority: cert.authority) }
                
                return Void()
            }
            .eraseToAnyPublisher()
    }

    public struct CertificateInfo {
        public var authority: [String]
        public var teamIdentifier: String
        public var bundleIdentifier: String
    }

    public func parseCertificateInfo(_ rawInfo: String) -> CertificateInfo {
        var info = CertificateInfo(authority: [], teamIdentifier: "", bundleIdentifier: "")

        for part in rawInfo.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines) {
            if part.hasPrefix("Authority") {
                info.authority.append(part.components(separatedBy: "=")[1])
            }
            if part.hasPrefix("TeamIdentifier") {
                info.teamIdentifier = part.components(separatedBy: "=")[1]
            }
            if part.hasPrefix("Identifier") {
                info.bundleIdentifier = part.components(separatedBy: "=")[1]
            }
        }

        return info
    }
    
    // MARK: - Post-Install
    
    /// Attemps to install the helper once, then performs all post-install steps
    public func performPostInstallSteps(for xcode: InstalledXcode) {
        performPostInstallSteps(for: xcode)
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        self.error = error
                    }
                }, 
                receiveValue: {}
            )
            .store(in: &cancellables)
    }
    
    /// Attemps to install the helper once, then performs all post-install steps
    public func performPostInstallSteps(for xcode: InstalledXcode) -> AnyPublisher<Void, Error> {
        let postInstallPublisher: AnyPublisher<Void, Error> =
            Deferred { [unowned self] in
                self.installHelperIfNecessary()
            }
            .flatMap { [unowned self] in
                self.enableDeveloperMode()
            }
            .flatMap { [unowned self] in
                self.approveLicense(for: xcode)
            }
            .flatMap { [unowned self] in
                self.installComponents(for: xcode)
            }
            .mapError { [unowned self] error in
                Logger.appState.error("Performing post-install steps failed: \(error.legibleLocalizedDescription)")
                return InstallationError.postInstallStepsNotPerformed(version: xcode.version, helperInstallState: self.helperInstallState)
            }
            .eraseToAnyPublisher()

        guard helperInstallState == .installed else {
            // If the helper isn't installed yet then we need to prepare the user for the install prompt,
            // and then actually perform the installation,
            // and the post-install steps need to wait until that is complete.
            // This subject, which completes upon isPreparingUserForActionRequiringHelper being invoked, is used to achieve that.
            // This is not the most straightforward code I've ever written...
            let helperInstallConsentSubject = PassthroughSubject<Void, Error>()

            // Need to dispatch this to avoid duplicate alerts, 
            // the second of which will crash when force-unwrapping isPreparingUserForActionRequiringHelper 
            DispatchQueue.main.async {
                self.isPreparingUserForActionRequiringHelper = { [unowned self] userConsented in
                    if userConsented {
                        helperInstallConsentSubject.send()
                    } else {
                        Logger.appState.info("User did not consent to installing helper during post-install steps.")

                        helperInstallConsentSubject.send(
                            completion: .failure(
                                InstallationError.postInstallStepsNotPerformed(version: xcode.version, helperInstallState: self.helperInstallState)
                            )
                        )
                    }
                }
            }

            return helperInstallConsentSubject
                .flatMap { 
                    postInstallPublisher 
                }
                .eraseToAnyPublisher()
        }
        
        return postInstallPublisher
    }

    private func enableDeveloperMode() -> AnyPublisher<Void, Error> {
        Current.helper.devToolsSecurityEnable()
            .flatMap {
                Current.helper.addStaffToDevelopersGroup()
            }
            .eraseToAnyPublisher()
    }

    private func approveLicense(for xcode: InstalledXcode) -> AnyPublisher<Void, Error> {
        Current.helper.acceptXcodeLicense(xcode.path.string)
            .eraseToAnyPublisher()
    }

    private func installComponents(for xcode: InstalledXcode) -> AnyPublisher<Void, Swift.Error> {
        Current.helper.runFirstLaunch(xcode.path.string)
            .flatMap {
                Current.shell.getUserCacheDir().map { $0.out }
                    .combineLatest(
                        Current.shell.buildVersion().map { $0.out },
                        Current.shell.xcodeBuildVersion(xcode).map { $0.out }
                    )
            }
            .flatMap { cacheDirectory, macOSBuildVersion, toolsVersion in
                Current.shell.touchInstallCheck(cacheDirectory, macOSBuildVersion, toolsVersion)
            }
            .map { _ in Void() }
            .eraseToAnyPublisher()
    }
    
    // MARK: - 
    
    func setInstallationStep(of version: Version, to step: InstallationStep) {
        DispatchQueue.main.async {
            guard let index = self.allXcodes.firstIndex(where: { $0.version.isEquivalent(to: version) }) else { return }
            self.allXcodes[index].installState = .installing(step)
        }
    }
}

extension AppState {
    func persistOrCleanUpResumeData<T>(at path: Path, for completion: Subscribers.Completion<T>) {
        switch completion {
        case .finished:
            try? Current.files.removeItem(at: path.url)
        case .failure(let error):
            guard let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data else { return }
            Current.files.createFile(atPath: path.string, contents: resumeData)
        }
    }
}

public enum InstallationError: LocalizedError, Equatable {
    case damagedXIP(url: URL)
    case notEnoughFreeSpaceToExpandArchive(archivePath: Path, version: Version)
    case failedToMoveXcodeToApplications
    case failedSecurityAssessment(xcode: InstalledXcode, output: String)
    case codesignVerifyFailed(output: String)
    case unexpectedCodeSigningIdentity(identifier: String, certificateAuthority: [String])
    case unsupportedFileFormat(extension: String)
    case missingSudoerPassword
    case unavailableVersion(Version)
    case noNonPrereleaseVersionAvailable
    case noPrereleaseVersionAvailable
    case missingUsernameOrPassword
    case versionAlreadyInstalled(InstalledXcode)
    case invalidVersion(String)
    case versionNotInstalled(Version)
    case postInstallStepsNotPerformed(version: Version, helperInstallState: HelperInstallState)

    public var errorDescription: String? {
        switch self {
        case .damagedXIP(let url):
            return "The archive \"\(url.lastPathComponent)\" is damaged and can't be expanded."
        case let .notEnoughFreeSpaceToExpandArchive(archivePath, version):
            return """
                   The archive “\(archivePath.basename())” can’t be expanded because the current volume doesn’t have enough free space.

                   Make more space available to expand the archive and then install Xcode \(version.appleDescription) again to start installation from where it left off.
                   """
        case .failedToMoveXcodeToApplications:
            return "Failed to move Xcode to the /Applications directory."
        case .failedSecurityAssessment(let xcode, let output):
            return """
                   Xcode \(xcode.version) failed its security assessment with the following output:
                   \(output)
                   It remains installed at \(xcode.path) if you wish to use it anyways.
                   """
        case .codesignVerifyFailed(let output):
            return """
                   The downloaded Xcode failed code signing verification with the following output:
                   \(output)
                   """
        case .unexpectedCodeSigningIdentity(let identity, let certificateAuthority):
            return """
                   The downloaded Xcode doesn't have the expected code signing identity.
                   Got:
                     \(identity)
                     \(certificateAuthority)
                   Expected:
                     \(XcodeTeamIdentifier)
                     \(XcodeCertificateAuthority)
                   """
        case .unsupportedFileFormat(let fileExtension):
            return "xcodes doesn't (yet) support installing Xcode from the \(fileExtension) file format."
        case .missingSudoerPassword:
            return "Missing password. Please try again."
        case let .unavailableVersion(version):
            return "Could not find version \(version.appleDescription)."
        case .noNonPrereleaseVersionAvailable:
            return "No non-prerelease versions available."
        case .noPrereleaseVersionAvailable:
            return "No prerelease versions available."
        case .missingUsernameOrPassword:
            return "Missing username or a password. Please try again."
        case let .versionAlreadyInstalled(installedXcode):
            return "\(installedXcode.version.appleDescription) is already installed at \(installedXcode.path)"
        case let .invalidVersion(version):
            return "\(version) is not a valid version number."
        case let .versionNotInstalled(version):
            return "\(version.appleDescription) is not installed."
        case let .postInstallStepsNotPerformed(version, helperInstallState):
            switch helperInstallState {
            case .installed:
                return "Installation was completed, but some post-install steps weren't performed automatically. These will be performed when you first launch Xcode \(version.appleDescription)."
            case .notInstalled, .unknown:
                return "Installation was completed, but some post-install steps weren't performed automatically. Xcodes performs these steps with a privileged helper, which appears to not be installed. You can install it from Preferences > Advanced.\n\nThese steps will be performed when you first launch Xcode \(version.appleDescription)."
            }
        }
    }
}

public enum InstallationType {
    case version(AvailableXcode)
}

let XcodeTeamIdentifier = "59GAB85EFG"
let XcodeCertificateAuthority = ["Software Signing", "Apple Code Signing Certification Authority", "Apple Root CA"]


public struct DownloadProgress: Equatable {
    var progress: Progress
    var speed: String?
    var total: String?
    var eta: String?
}
