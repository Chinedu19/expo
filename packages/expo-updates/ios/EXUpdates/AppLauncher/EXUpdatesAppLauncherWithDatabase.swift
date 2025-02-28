//  Copyright © 2019 650 Industries. All rights reserved.

// swiftlint:disable type_body_length
// swiftlint:disable closure_body_length
// swiftlint:disable force_unwrapping
// swiftlint:disable type_name

import Foundation

public typealias EXUpdatesAppLauncherUpdateCompletionBlock = (Error?, EXUpdatesUpdate?) -> Void
public typealias EXUpdatesAppLauncherQueryCompletionBlock = (Error?, [UUID]?) -> Void

/**
 * Implementation of EXUpdatesAppLauncher that uses the SQLite database and expo-updates file store
 * as the source of updates.
 *
 * Uses the EXUpdatesSelectionPolicy to choose an update from SQLite to launch, then ensures that
 * the update is safe and ready to launch (i.e. all the assets that SQLite expects to be stored on
 * disk are actually there).
 *
 * This class also includes failsafe code to attempt to re-download any assets unexpectedly missing
 * from disk (since it isn't necessarily safe to just revert to an older update in this case).
 * Distinct from the EXUpdatesAppLoader classes, though, this class does *not* make any major
 * modifications to the database; its role is mostly to read the database and ensure integrity with
 * the file system.
 *
 * It's important that the update to launch is selected *before* any other checks, e.g. the above
 * check for assets on disk. This is to preserve the invariant that no older update should ever be
 * launched after a newer one has been launched.
 */
@objcMembers
public class EXUpdatesAppLauncherWithDatabase: NSObject, EXUpdatesAppLauncher {
  private static let EXUpdatesAppLauncherErrorDomain = "AppLauncher"

  public var launchedUpdate: EXUpdatesUpdate?
  public var launchAssetUrl: URL?
  public var assetFilesMap: [String: Any]?

  private let launcherQueue: DispatchQueue
  private var completedAssets: Int
  private let config: EXUpdatesConfig
  private let database: EXUpdatesDatabase
  private let directory: URL
  public private(set) var completionQueue: DispatchQueue
  public private(set) var completion: EXUpdatesAppLauncherCompletionBlock?

  private var launchAssetError: Error?

  public required init(config: EXUpdatesConfig, database: EXUpdatesDatabase, directory: URL, completionQueue: DispatchQueue) {
    self.launcherQueue = DispatchQueue(label: "expo.launcher.LauncherQueue")
    self.completedAssets = 0
    self.config = config
    self.database = database
    self.directory = directory
    self.completionQueue = completionQueue
  }

  public func isUsingEmbeddedAssets() -> Bool {
    return assetFilesMap == nil
  }

  public static func launchableUpdate(
    withConfig config: EXUpdatesConfig,
    database: EXUpdatesDatabase,
    selectionPolicy: EXUpdatesSelectionPolicy,
    completionQueue: DispatchQueue,
    completion: @escaping EXUpdatesAppLauncherUpdateCompletionBlock
  ) {
    database.databaseQueue.async {
      var launchableUpdates: [EXUpdatesUpdate]?
      var launchableUpdatesError: Error?
      do {
        launchableUpdates = try database.launchableUpdates(withConfig: config)
      } catch {
        launchableUpdatesError = error
      }

      var manifestFilters: [String: Any]?
      var manifestFiltersError: Error?
      do {
        manifestFilters = try database.manifestFilters(withScopeKey: config.scopeKey!).jsonData
      } catch {
        manifestFiltersError = error
      }

      completionQueue.async {
        guard let launchableUpdates = launchableUpdates else {
          completion(launchableUpdatesError!, nil)
          return
        }

        if let manifestFiltersError = manifestFiltersError {
          completion(manifestFiltersError, nil)
          return
        }

        // We can only run an update marked as embedded if it's actually the update embedded in the
        // current binary. We might have an older update from a previous binary still listed in the
        // database with Embedded status so we need to filter that out here.
        let embeddedManifest = EXUpdatesEmbeddedAppLoader.embeddedManifest(withConfig: config, database: database)
        var filteredLaunchableUpdates: [EXUpdatesUpdate] = []

        for update in launchableUpdates {
          if update.status == EXUpdatesUpdateStatus.StatusEmbedded {
            if embeddedManifest != nil && update.updateId != embeddedManifest!.updateId {
              continue
            }
          }
          filteredLaunchableUpdates.append(update)
        }

        completion(nil, selectionPolicy.launchableUpdate(fromUpdates: filteredLaunchableUpdates, filters: manifestFilters))
      }
    }
  }

  public func launchableUpdate(
    selectionPolicy: EXUpdatesSelectionPolicy,
    completion: @escaping EXUpdatesAppLauncherUpdateCompletionBlock
  ) {
    EXUpdatesAppLauncherWithDatabase.launchableUpdate(
      withConfig: config,
      database: database,
      selectionPolicy: selectionPolicy,
      completionQueue: completionQueue,
      completion: completion
    )
  }

  public func launchUpdate(
    withSelectionPolicy selectionPolicy: EXUpdatesSelectionPolicy,
    completion: @escaping EXUpdatesAppLauncherCompletionBlock
  ) {
    precondition(self.completion == nil, "EXUpdatesAppLauncher:launchUpdateWithSelectionPolicy:successBlock should not be called twice on the same instance")
    self.completion = completion

    if launchedUpdate == nil {
      launchableUpdate(selectionPolicy: selectionPolicy) { error, launchableUpdate in
        if error != nil || launchableUpdate == nil {
          if let completionInner = self.completion {
            self.completionQueue.async {
              var userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: "No launchable updates found in database"
              ]
              if let error = error {
                userInfo[NSUnderlyingErrorKey] = error
              }
              completionInner(NSError(domain: EXUpdatesAppLauncherWithDatabase.EXUpdatesAppLauncherErrorDomain, code: 1011, userInfo: userInfo), false)
            }
          }
        } else {
          self.launchedUpdate = launchableUpdate
          self.finishLaunch()
        }
      }
    } else {
      finishLaunch()
    }
  }

  public static func storedUpdateIds(
    inDatabase database: EXUpdatesDatabase,
    completion: @escaping EXUpdatesAppLauncherQueryCompletionBlock
  ) {
    database.databaseQueue.async {
      do {
        let readyUpdateIds = try database.allUpdateIds(withStatus: .StatusReady)
        completion(nil, readyUpdateIds)
      } catch {
        completion(error, nil)
      }
    }
  }

  private func finishLaunch() {
    markUpdateAccessed()
    ensureAllAssetsExist()
  }

  private func markUpdateAccessed() {
    guard launchedUpdate != nil else {
      preconditionFailure("launchedUpdate should be nonnull before calling markUpdateAccessed")
    }
    database.databaseQueue.async {
      do {
        try self.database.markUpdateAccessed(self.launchedUpdate!)
      } catch {
        NSLog("Failed to mark update as recently accessed: %@", error.localizedDescription)
      }
    }
  }

  public func ensureAllAssetsExist() {
    guard let launchedUpdate = launchedUpdate else {
      preconditionFailure("launchedUpdate should be nonnull before calling markUpdateAccessed")
    }

    if launchedUpdate.status == EXUpdatesUpdateStatus.StatusEmbedded {
      precondition(assetFilesMap == nil, "assetFilesMap should be null for embedded updates")
      launchAssetUrl = Bundle.main.url(
        forResource: EXUpdatesEmbeddedAppLoader.EXUpdatesBareEmbeddedBundleFilename,
        withExtension: EXUpdatesEmbeddedAppLoader.EXUpdatesBareEmbeddedBundleFileType
      )

      completionQueue.async {
        self.completion!(self.launchAssetError, self.launchAssetUrl != nil)
        self.completion = nil
      }
      return
    } else if launchedUpdate.status == EXUpdatesUpdateStatus.StatusDevelopment {
      completionQueue.async {
        self.completion!(nil, true)
        self.completion = nil
      }
      return
    }

    assetFilesMap = [:]

    let assets = launchedUpdate.assets()!
    let totalAssetCount = assets.count
    for asset in assets {
      let assetLocalUrl = directory.appendingPathComponent(asset.filename)
      ensureAssetExists(asset: asset, withLocalUrl: assetLocalUrl) { exists in
        dispatchPrecondition(condition: .onQueue(self.launcherQueue))
        self.completedAssets += 1

        if exists {
          if asset.isLaunchAsset {
            self.launchAssetUrl = assetLocalUrl
          } else {
            if let assetKey = asset.key {
              self.assetFilesMap![assetKey] = assetLocalUrl.absoluteString
            }
          }
        }

        if self.completedAssets == totalAssetCount {
          self.completionQueue.async {
            self.completion!(self.launchAssetError, self.launchAssetUrl != nil)
            self.completion = nil
          }
        }
      }
    }
  }

  private func ensureAssetExists(asset: EXUpdatesAsset, withLocalUrl assetLocalUrl: URL, completion: @escaping (Bool) -> Void) {
    checkExistence(ofAsset: asset, withLocalUrl: assetLocalUrl) { exists in
      if exists {
        completion(true)
        return
      }

      self.maybeCopyAssetFromMainBundle(asset, withLocalUrl: assetLocalUrl) { success, error in
        if success {
          completion(true)
          return
        }

        if let error = error {
          NSLog("Error copying embedded asset %@: %@", [asset.key, error.localizedDescription])
        }

        self.downloadAsset(asset, withLocalUrl: assetLocalUrl) { downloadAssetError, downloadAssetAsset, _ in
          if let downloadAssetError = downloadAssetError {
            if downloadAssetAsset.isLaunchAsset {
              // save the error -- since this is the launch asset, the launcher will fail
              // so we want to propagate this error
              self.launchAssetError = downloadAssetError
            }
            NSLog("Failed to load missing asset %@: %@", [downloadAssetAsset.key, downloadAssetError.localizedDescription])
            completion(false)
          } else {
            // attempt to update the database record to match the newly downloaded asset
            // but don't block launching on this
            self.database.databaseQueue.async {
              do {
                try self.database.updateAsset(downloadAssetAsset)
              } catch {
                NSLog("Could not write data for downloaded asset to database: %@", [error.localizedDescription])
              }
            }
            completion(true)
          }
        }
      }
    }
  }

  private func checkExistence(ofAsset asset: EXUpdatesAsset, withLocalUrl assetLocalUrl: URL, completion: @escaping (Bool) -> Void) {
    EXUpdatesFileDownloader.assetFilesQueue.async {
      let exists = FileManager.default.fileExists(atPath: assetLocalUrl.path)
      self.launcherQueue.async {
        completion(exists)
      }
    }
  }

  private func maybeCopyAssetFromMainBundle(
    _ asset: EXUpdatesAsset,
    withLocalUrl assetLocalUrl: URL,
    completion: @escaping (Bool, Error?) -> Void
  ) {
    guard let embeddedManifest = EXUpdatesEmbeddedAppLoader.embeddedManifest(withConfig: config, database: database) else {
      completion(false, nil)
      return
    }

    let matchingAsset = embeddedManifest.assets()!.first { embeddedAsset in
      return embeddedAsset.key != nil && embeddedAsset.key == asset.key
    }

    if let matchingAsset = matchingAsset, matchingAsset.mainBundleFilename != nil {
      EXUpdatesFileDownloader.assetFilesQueue.async {
        guard let bundlePath = EXUpdatesUtils.path(forBundledAsset: matchingAsset) else {
          self.launcherQueue.async {
            completion(
              false,
              NSError(
                domain: EXUpdatesAppLauncherWithDatabase.EXUpdatesAppLauncherErrorDomain,
                code: 1013,
                userInfo: [NSLocalizedDescriptionKey: "Asset bundlePath was unexpectedly nil"]
              )
            )
          }
          return
        }

        do {
          try FileManager.default.copyItem(atPath: bundlePath, toPath: assetLocalUrl.path)
          self.launcherQueue.async {
            completion(true, nil)
          }
        } catch {
          self.launcherQueue.async {
            completion(
              false,
              NSError(
                domain: EXUpdatesAppLauncherWithDatabase.EXUpdatesAppLauncherErrorDomain,
                code: 1013,
                userInfo: [NSLocalizedDescriptionKey: "Asset copy failed"]
              )
            )
          }
        }
      }
      return
    } else {
      self.launcherQueue.async {
        completion(false, nil)
      }
    }
  }

  private func downloadAsset(_ asset: EXUpdatesAsset, withLocalUrl assetLocalUrl: URL, completion: @escaping (Error?, EXUpdatesAsset, URL) -> Void) {
    guard let assetUrl = asset.url else {
      completion(
        NSError(
          domain: EXUpdatesAppLauncherWithDatabase.EXUpdatesAppLauncherErrorDomain,
          code: 1007,
          userInfo: [NSLocalizedDescriptionKey: "Failed to download asset with no URL provided"]
        ),
        asset,
        assetLocalUrl
      )
      return
    }

    EXUpdatesFileDownloader.assetFilesQueue.async {
      self.downloader.downloadFile(
        fromURL: assetUrl,
        verifyingHash: asset.expectedHash,
        toPath: assetLocalUrl.path,
        extraHeaders: asset.extraRequestHeaders ?? [:]
      ) { _, response, base64URLEncodedSHA256Hash in
        self.launcherQueue.async {
          if let response = response as? HTTPURLResponse {
            asset.headers = response.allHeaderFields as? [String: Any]
          }
          asset.contentHash = base64URLEncodedSHA256Hash
          asset.downloadTime = Date()
          completion(nil, asset, assetLocalUrl)
        }
      } errorBlock: { error in
        self.launcherQueue.async {
          completion(error, asset, assetLocalUrl)
        }
      }
    }
  }

  private lazy var downloader: EXUpdatesFileDownloader = {
    EXUpdatesFileDownloader(config: config)
  }()
}
