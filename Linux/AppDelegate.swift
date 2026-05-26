//
//  AppDelegate.swift
//  Linux
//
//  Created by Bengin Sternas on 26.05.26.
//  Copyright © 2026 Bengin Sternas. All rights reserved.
//

import Virtualization

// MARK: - VM Bundle and Storage Path Configuration

/// The target base path where the virtual machine bundle is stored.
/// Putting this inside the standard "Virtual Machines" subdirectory keeps the user's home folder clean and organized.
let vmBundlePath = NSHomeDirectory() + "/Virtual Machines/GUI Linux VM.bundle/"

/// The absolute path of the paravirtualized primary disk image.
let mainDiskImagePath = vmBundlePath + "Disk.img"

/// The absolute path of the EFI NVRAM variable store.
let efiVariableStorePath = vmBundlePath + "NVRAM"

/// The absolute path of the machine identifier for persistence.
let machineIdentifierPath = vmBundlePath + "MachineIdentifier"

@main
class AppDelegate: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {

    // MARK: - IBOutlets

    @IBOutlet var window: NSWindow!

    @IBOutlet weak var virtualMachineView: VZVirtualMachineView!

    // MARK: - Private Properties

    /// The virtual machine instance.
    private var virtualMachine: VZVirtualMachine!

    /// The URL of the installer ISO image, used when setting up the VM for the first time.
    private var installerISOPath: URL?

    /// Flag indicating whether the virtual machine needs a fresh installation.
    private var needsInstall = true

    // MARK: - Initializer

    override init() {
        super.init()
    }

    // MARK: - VM Bundle & Disk Initialization

    /// Creates the main virtual machine bundle directory.
    private func createVMBundle() {
        do {
            // Using withIntermediateDirectories: true ensures the parent "Virtual Machines" directory is automatically created if it does not exist.
            try FileManager.default.createDirectory(atPath: vmBundlePath, withIntermediateDirectories: true)
        } catch {
            fatalError("Failed to create virtual machine bundle directory at: \(vmBundlePath)")
        }
    }

    /// Creates an empty primary disk image for the virtual machine guest OS.
    private func createMainDiskImage() {
        let diskCreated = FileManager.default.createFile(atPath: mainDiskImagePath, contents: nil, attributes: nil)
        if !diskCreated {
            fatalError("Failed to create the main disk image.")
        }

        guard let mainDiskFileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: mainDiskImagePath)) else {
            fatalError("Failed to acquire write-handle for the main disk image.")
        }

        do {
            // Pre-allocate a 64 GB sparse disk image for the guest OS.
            try mainDiskFileHandle.truncate(atOffset: 64 * 1024 * 1024 * 1024)
        } catch {
            fatalError("Failed to pre-allocate/truncate the main disk image space.")
        }
    }

    // MARK: - Virtual Device Configurations

    /// Configures the paravirtualized primary block device.
    /// - Returns: A configured `VZVirtioBlockDeviceConfiguration` instance.
    private func createBlockDeviceConfiguration() -> VZVirtioBlockDeviceConfiguration {
        guard let mainDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: mainDiskImagePath), readOnly: false) else {
            fatalError("Failed to create main disk storage device attachment.")
        }

        let mainDisk = VZVirtioBlockDeviceConfiguration(attachment: mainDiskAttachment)
        return mainDisk
    }

    /// Computes the CPU count for the guest VM based on physical performance cores.
    ///
    /// Dynamically queries physical performance cores (P-Cores) on Apple Silicon to ensure threads execute exclusively
    /// on high-speed hardware blocks, avoiding context switching overhead with efficiency (E) cores.
    /// - Returns: The number of CPU cores to allocate.
    private func computeCPUCount() -> Int {
        var performanceCores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.perflevel0.physicalcpu", &performanceCores, &size, nil, 0)

        var virtualCPUCount: Int
        if result == 0 && performanceCores > 0 {
            // Allocate exactly the number of physical performance cores to bypass E-cores.
            virtualCPUCount = Int(performanceCores)
        } else {
            // Fallback for Intel or systems where sysctl fails.
            let totalAvailableCPUs = ProcessInfo.processInfo.processorCount
            virtualCPUCount = totalAvailableCPUs <= 1 ? 1 : totalAvailableCPUs - 1
        }

        virtualCPUCount = max(virtualCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        virtualCPUCount = min(virtualCPUCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)

        return virtualCPUCount
    }

    /// Computes the RAM allocation for the guest VM.
    ///
    /// Allocates a stable, standard 4 GiB RAM configuration to prevent host-side memory pressure
    /// and page-swapping delays on the host SSD.
    /// - Returns: Memory size in bytes.
    private func computeMemorySize() -> UInt64 {
        var memorySize = (4 * 1024 * 1024 * 1024) as UInt64 // 4 GiB
        memorySize = max(memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        memorySize = min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        return memorySize
    }

    /// Generates and persists a generic machine identifier.
    /// - Returns: The newly created `VZGenericMachineIdentifier`.
    private func createAndSaveMachineIdentifier() -> VZGenericMachineIdentifier {
        let machineIdentifier = VZGenericMachineIdentifier()

        // Store the machine identifier to disk so it can be restored on subsequent boots.
        try! machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: machineIdentifierPath))
        return machineIdentifier
    }

    /// Restores a previously saved generic machine identifier from disk.
    /// - Returns: The retrieved `VZGenericMachineIdentifier`.
    private func retrieveMachineIdentifier() -> VZGenericMachineIdentifier {
        guard let machineIdentifierData = try? Data(contentsOf: URL(fileURLWithPath: machineIdentifierPath)) else {
            fatalError("Failed to retrieve the machine identifier data.")
        }

        guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            fatalError("Failed to restore the machine identifier.")
        }

        return machineIdentifier
    }

    /// Creates a fresh EFI variable NVRAM store.
    /// - Returns: The newly created `VZEFIVariableStore`.
    private func createEFIVariableStore() -> VZEFIVariableStore {
        guard let efiVariableStore = try? VZEFIVariableStore(creatingVariableStoreAt: URL(fileURLWithPath: efiVariableStorePath)) else {
            fatalError("Failed to create the EFI variable store.")
        }

        return efiVariableStore
    }

    /// Restores the existing EFI variable NVRAM store.
    /// - Returns: The retrieved `VZEFIVariableStore`.
    private func retrieveEFIVariableStore() -> VZEFIVariableStore {
        if !FileManager.default.fileExists(atPath: efiVariableStorePath) {
            fatalError("EFI variable store NVRAM file does not exist.")
        }

        return VZEFIVariableStore(url: URL(fileURLWithPath: efiVariableStorePath))
    }

    /// Configures a USB mass storage device mapping the installer ISO image.
    /// - Returns: A configured `VZUSBMassStorageDeviceConfiguration`.
    private func createUSBMassStorageDeviceConfiguration() -> VZUSBMassStorageDeviceConfiguration {
        guard let installerDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: installerISOPath!, readOnly: true) else {
            fatalError("Failed to create installer's disk attachment.")
        }

        return VZUSBMassStorageDeviceConfiguration(attachment: installerDiskAttachment)
    }

    /// Configures a paravirtualized network interface using NAT (Network Address Translation).
    /// - Returns: A configured `VZVirtioNetworkDeviceConfiguration`.
    private func createNetworkDeviceConfiguration() -> VZVirtioNetworkDeviceConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()

        return networkDevice
    }

    /// Configures a paravirtualized Virtio graphics device.
    /// - Returns: A configured `VZVirtioGraphicsDeviceConfiguration`.
    private func createGraphicsDeviceConfiguration() -> VZVirtioGraphicsDeviceConfiguration {
        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        graphicsDevice.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)
        ]

        return graphicsDevice
    }

    /// Configures the paravirtualized audio input stream (Microphone).
    /// - Returns: A configured `VZVirtioSoundDeviceConfiguration`.
    private func createInputAudioDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
        let inputAudioDevice = VZVirtioSoundDeviceConfiguration()
        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()

        inputAudioDevice.streams = [inputStream]
        return inputAudioDevice
    }

    /// Configures the paravirtualized audio output stream (Speakers).
    /// - Returns: A configured `VZVirtioSoundDeviceConfiguration`.
    private func createOutputAudioDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
        let outputAudioDevice = VZVirtioSoundDeviceConfiguration()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()

        outputAudioDevice.streams = [outputStream]
        return outputAudioDevice
    }

    /// Configures a Spice Agent console device to support guest-to-host integrations like clipboard sharing.
    /// - Returns: A configured `VZVirtioConsoleDeviceConfiguration`.
    private func createSpiceAgentConsoleDeviceConfiguration() -> VZVirtioConsoleDeviceConfiguration {
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()
        let spiceAgentPort = VZVirtioConsolePortConfiguration()
        spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        spiceAgentPort.attachment = VZSpiceAgentPortAttachment()
        consoleDevice.ports[0] = spiceAgentPort

        return consoleDevice
    }

    /// Configures a Virtio entropy device to provide a hardware source of randomness to the guest OS.
    /// This prevents entropy starvation, which causes severe delays (often ~1 minute) when launching applications.
    /// - Returns: A configured `VZVirtioEntropyDeviceConfiguration`.
    private func createEntropyDeviceConfiguration() -> VZVirtioEntropyDeviceConfiguration {
        return VZVirtioEntropyDeviceConfiguration()
    }

    // MARK: - VM Creation and Lifecycle Management

    /// Compiles all virtual device configurations, instantiates the VM, and performs integrity validation.
    func createVirtualMachine() {
        let virtualMachineConfiguration = VZVirtualMachineConfiguration()

        virtualMachineConfiguration.cpuCount = computeCPUCount()
        virtualMachineConfiguration.memorySize = computeMemorySize()

        let platform = VZGenericPlatformConfiguration()
        let bootloader = VZEFIBootLoader()
        let disksArray = NSMutableArray()

        if needsInstall {
            // Fresh install path: Generate persistent identifier & variable store and plug in the ISO
            platform.machineIdentifier = createAndSaveMachineIdentifier()
            bootloader.variableStore = createEFIVariableStore()
            disksArray.add(createUSBMassStorageDeviceConfiguration())
        } else {
            // Subsequent boot path: Restore persistent identity and variables
            platform.machineIdentifier = retrieveMachineIdentifier()
            bootloader.variableStore = retrieveEFIVariableStore()
        }

        virtualMachineConfiguration.platform = platform
        virtualMachineConfiguration.bootLoader = bootloader

        // Mount primary OS virtual disk image
        disksArray.add(createBlockDeviceConfiguration())
        guard let disks = disksArray as? [VZStorageDeviceConfiguration] else {
            fatalError("Invalid storage devices array configuration.")
        }
        virtualMachineConfiguration.storageDevices = disks

        // Attach communication, display, input, sound, and input devices
        virtualMachineConfiguration.networkDevices = [createNetworkDeviceConfiguration()]
        virtualMachineConfiguration.graphicsDevices = [createGraphicsDeviceConfiguration()]
        virtualMachineConfiguration.audioDevices = [createInputAudioDeviceConfiguration(), createOutputAudioDeviceConfiguration()]
        virtualMachineConfiguration.entropyDevices = [createEntropyDeviceConfiguration()]

        virtualMachineConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
        virtualMachineConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        virtualMachineConfiguration.consoleDevices = [createSpiceAgentConsoleDeviceConfiguration()]

        // Perform configuration validation check before booting
        try! virtualMachineConfiguration.validate()
        virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
    }

    /// Initializes and boots the virtual machine asynchronously.
    func configureAndStartVirtualMachine() {
        DispatchQueue.main.async {
            self.createVirtualMachine()

            // Programmatic fallback: If the virtualMachineView outlet was not connected in the storyboard,
            // the window content view is retrieved to dynamically instantiate and embed the VZVirtualMachineView.
            if self.virtualMachineView == nil {
                guard let window = NSApp.windows.first(where: { $0.isKeyWindow || $0.isVisible }) ?? NSApp.windows.first else {
                    fatalError("Failed to find the main application window.")
                }

                guard let contentView = window.contentView else {
                    fatalError("Failed to find the main window's contentView.")
                }

                let vmView = VZVirtualMachineView(frame: contentView.bounds)
                vmView.autoresizingMask = [.width, .height]
                contentView.addSubview(vmView)

                self.virtualMachineView = vmView
            }

            self.virtualMachineView.virtualMachine = self.virtualMachine

            if #available(macOS 14.0, *) {
                // Configures the view to automatically scale the guest display resolution
                // when the macOS host window is resized.
                self.virtualMachineView.automaticallyReconfiguresDisplay = true
            }

            self.virtualMachine.delegate = self
            self.virtualMachine.start(completionHandler: { (result) in
                switch result {
                case let .failure(error):
                    fatalError("Virtual machine failed to start with error: \(error)")

                default:
                    print("Virtual machine successfully started.")
                }
            })
        }
    }

    // MARK: - NSApplicationDelegate Methods

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        // Boot state check: If the target bundle path does not exist, a fresh OS installation is initiated.
        // Otherwise, boot directly from the primary virtual disk inside the bundle.
        if !FileManager.default.fileExists(atPath: vmBundlePath) {
            needsInstall = true
            createVMBundle()
            createMainDiskImage()

            // Open panel requesting the user to select the Linux installation ISO image
            let openPanel = NSOpenPanel()
            openPanel.title = "Select Linux Installation ISO"
            openPanel.canChooseFiles = true
            openPanel.allowsMultipleSelection = false
            openPanel.canChooseDirectories = false
            openPanel.canCreateDirectories = false

            openPanel.begin { (result) -> Void in
                if result == .OK {
                    self.installerISOPath = openPanel.url!
                    self.configureAndStartVirtualMachine()
                } else {
                    fatalError("ISO installation file was not selected.")
                }
            }
        } else {
            needsInstall = false
            configureAndStartVirtualMachine()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If the virtual machine is running, initiate a graceful ACPI shutdown.
        if virtualMachine != nil && virtualMachine.state == .running {
            if virtualMachine.canRequestStop {
                do {
                    try virtualMachine.requestStop()
                    print("Sent graceful shutdown request to the guest OS.")
                    // Postpone termination until the guest OS completes its shutdown sequence.
                    // The delegate method guestDidStop(_:) will handle the final exit.
                    return .terminateLater
                } catch {
                    print("Failed to request graceful stop: \(error.localizedDescription)")
                }
            }
        }
        return .terminateNow
    }

    // MARK: - VZVirtualMachineDelegate Methods

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("Virtual machine encountered runtime crash/error: \(error.localizedDescription)")
        exit(-1)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("Guest OS gracefully shut down the virtual machine.")
        NSApp.reply(toApplicationShouldTerminate: true)
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        print("Network attachment disconnected with error: \(error.localizedDescription)")
    }
}
