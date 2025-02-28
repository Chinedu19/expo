//  Copyright © 2019 650 Industries. All rights reserved.

// swiftlint:disable identifier_name
// swiftlint:disable legacy_objc_type

// this class uses an abstract class pattern
// swiftlint:disable unavailable_function

import Foundation

/**
 * Subclass of EXUpdatesAppLoader which handles copying the embedded update's assets into the
 * expo-updates cache location.
 *
 * Rather than launching the embedded update directly from its location in the app bundle/apk, we
 * first try to read it into the expo-updates cache and database and launch it like any other
 * update. The benefits of this include (a) a single code path for launching most updates and (b)
 * assets included in embedded updates and copied into the cache in this way do not need to be
 * redownloaded if included in future updates.
 */
@objcMembers
public final class EXUpdatesEmbeddedAppLoader: EXUpdatesAppLoader {
  public static let EXUpdatesEmbeddedManifestName = "app"
  public static let EXUpdatesEmbeddedManifestType = "manifest"
  public static let EXUpdatesEmbeddedBundleFilename = "app"
  public static let EXUpdatesEmbeddedBundleFileType = "bundle"
  public static let EXUpdatesBareEmbeddedBundleFilename = "main"
  public static let EXUpdatesBareEmbeddedBundleFileType = "jsbundle"

  private static let EXUpdatesEmbeddedAppLoaderErrorDomain = "EXUpdatesEmbeddedAppLoader"

  private static var embeddedManifestInternal: EXUpdatesUpdate?
  public static func embeddedManifest(withConfig config: EXUpdatesConfig, database: EXUpdatesDatabase?) -> EXUpdatesUpdate? {
    guard config.hasEmbeddedUpdate else {
      return nil
    }
    if let embeddedManifestInternal = embeddedManifestInternal {
      return embeddedManifestInternal
    }

    var manifestNSData: NSData?

    let frameworkBundle = Bundle(for: EXUpdatesEmbeddedAppLoader.self)
    if let resourceUrl = frameworkBundle.resourceURL,
      let bundle = Bundle(url: resourceUrl.appendingPathComponent("EXUpdates.bundle")),
      let path = bundle.path(
        forResource: EXUpdatesEmbeddedAppLoader.EXUpdatesEmbeddedManifestName,
        ofType: EXUpdatesEmbeddedAppLoader.EXUpdatesEmbeddedManifestType
      ) {
      manifestNSData = NSData(contentsOfFile: path)
    }

    // Fallback to main bundle if the embedded manifest is not found in EXUpdates.bundle. This is a special case
    // to support the existing structure of Expo "shell apps"
    if manifestNSData == nil,
      let path = Bundle.main.path(
        forResource: EXUpdatesEmbeddedAppLoader.EXUpdatesEmbeddedManifestName,
        ofType: EXUpdatesEmbeddedAppLoader.EXUpdatesEmbeddedManifestType
      ) {
      manifestNSData = NSData(contentsOfFile: path)
    }

    let manifestData = manifestNSData.let { it in
      it as Data
    }

    // Not found in EXUpdates.bundle or main bundle
    guard let manifestData = manifestData else {
      NSException(
        name: .internalInconsistencyException,
        reason: "The embedded manifest is invalid or could not be read. Make sure you have configured expo-updates correctly in your Xcode Build Phases."
      )
      .raise()
      return nil
    }

    guard let manifest = try? JSONSerialization.jsonObject(with: manifestData) else {
      NSException(
        name: .internalInconsistencyException,
        reason: "The embedded manifest is invalid or could not be read. Make sure you have configured expo-updates correctly in your Xcode Build Phases."
      )
      .raise()
      return nil
    }

    guard let manifestDictionary = manifest as? [String: Any] else {
      NSException(
        name: .internalInconsistencyException,
        reason: "embedded manifest should be a valid JSON file"
      )
      .raise()
      return nil
    }

    var mutableManifest = manifestDictionary
    // automatically verify embedded manifest since it was already codesigned
    mutableManifest["isVerified"] = true
    embeddedManifestInternal = EXUpdatesUpdate.update(withEmbeddedManifest: mutableManifest, config: config, database: database)
    return embeddedManifestInternal
  }

  public func loadUpdateFromEmbeddedManifest(
    withCallback manifestBlock: @escaping EXUpdatesAppLoaderManifestBlock,
    asset assetBlock: @escaping EXUpdatesAppLoaderAssetBlock,
    success successBlock: @escaping EXUpdatesAppLoaderSuccessBlock,
    error errorBlock: @escaping EXUpdatesAppLoaderErrorBlock
  ) {
    guard let embeddedManifest = EXUpdatesEmbeddedAppLoader.embeddedManifest(withConfig: config, database: database) else {
      errorBlock(NSError(
        domain: EXUpdatesEmbeddedAppLoader.EXUpdatesEmbeddedAppLoaderErrorDomain,
        code: 1008,
        userInfo: [
          NSLocalizedDescriptionKey: "Failed to load embedded manifest. Make sure you have configured expo-updates correctly."
        ]
      ))
      return
    }

    self.manifestBlock = manifestBlock
    self.assetBlock = assetBlock
    self.successBlock = successBlock
    self.errorBlock = errorBlock
    startLoading(fromManifest: embeddedManifest)
  }

  override public func downloadAsset(_ asset: EXUpdatesAsset) {
    let destinationUrl = directory.appendingPathComponent(asset.filename)
    EXUpdatesFileDownloader.assetFilesQueue.async {
      if FileManager.default.fileExists(atPath: destinationUrl.path) {
        DispatchQueue.global().async {
          self.handleAssetDownloadAlreadyExists(asset)
        }
      } else {
        let mainBundleFilename = asset.mainBundleFilename.require("embedded asset mainBundleFilename must be nonnull")
        let bundlePath = EXUpdatesUtils.path(forBundledAsset: asset).require(
          String(
            format: "Could not find the expected embedded asset in NSBundle %@.%@. Check that expo-updates is installed correctly.",
            mainBundleFilename,
            asset.type ?? ""
          )
        )

        do {
          try FileManager.default.copyItem(atPath: bundlePath, toPath: destinationUrl.path)
          let data = try NSData(contentsOfFile: bundlePath) as Data
          DispatchQueue.global().async {
            self.handleAssetDownload(withData: data, response: nil, asset: asset)
          }
        } catch {
          DispatchQueue.global().async {
            self.handleAssetDownload(withError: error, asset: asset)
          }
        }
      }
    }
  }

  override public func loadUpdate(
    fromURL url: URL,
    onManifest manifestBlock: @escaping EXUpdatesAppLoaderManifestBlock,
    asset assetBlock: @escaping EXUpdatesAppLoaderAssetBlock,
    success successBlock: @escaping EXUpdatesAppLoaderSuccessBlock,
    error errorBlock: @escaping EXUpdatesAppLoaderErrorBlock
  ) {
    preconditionFailure("Should not call EXUpdatesEmbeddedAppLoader#loadUpdateFromUrl")
  }
}
