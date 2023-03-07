package expo.modules.devlauncher

import android.app.Application
import android.content.Context
import android.content.Intent
import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.ReactApplication
import com.facebook.react.ReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.uimanager.ViewManager
import expo.modules.core.interfaces.ApplicationLifecycleListener
import expo.modules.core.interfaces.Package
import expo.modules.core.interfaces.ReactActivityHandler
import expo.modules.core.interfaces.ReactActivityLifecycleListener
import expo.modules.core.interfaces.ReactNativeHostHandler
import expo.modules.devlauncher.launcher.DevLauncherReactActivityDelegateSupplier
import expo.modules.devlauncher.modules.DevLauncherAuth
import expo.modules.devlauncher.modules.DevLauncherDevMenuExtension
import expo.modules.devlauncher.modules.DevLauncherInternalModule
import expo.modules.devlauncher.modules.DevLauncherModule
import expo.modules.devlauncher.rncompatibility.DevLauncherReactNativeHostHandler
import expo.modules.devmenu.modules.DevMenuPreferences

object DevLauncherPackageDelegate {
  @JvmField
  var enableAutoSetup: Boolean? = null
  internal val shouldEnableAutoSetup: Boolean by lazy {
    if (enableAutoSetup != null) {
      // if someone else has set this explicitly, use that value
      return@lazy enableAutoSetup!!
    }
    if (DevLauncherController.wasInitialized()) {
      // Backwards compatibility -- if the MainApplication has already set up expo-dev-launcher,
      // we just skip auto-setup in this case.
      return@lazy false
    }
    return@lazy true
  }
}

class DevLauncherPackage : Package, ReactPackage {
  override fun createNativeModules(reactContext: ReactApplicationContext): List<NativeModule> =
    listOf(
      DevLauncherModule(reactContext),
      DevLauncherInternalModule(reactContext),
      DevLauncherDevMenuExtension(reactContext),
      DevLauncherAuth(reactContext),
      DevMenuPreferences(reactContext)
    )

  override fun createViewManagers(reactContext: ReactApplicationContext): List<ViewManager<*, *>> = emptyList()

  override fun createApplicationLifecycleListeners(context: Context?): List<ApplicationLifecycleListener> =
    listOf(
      object : ApplicationLifecycleListener {
        override fun onCreate(application: Application?) {
          if (DevLauncherPackageDelegate.shouldEnableAutoSetup && application != null && application is ReactApplication) {
            DevLauncherController.initialize(application, application.reactNativeHost)
            DevLauncherUpdatesInterfaceDelegate.initializeUpdatesInterface(application)
          }
        }
      }
    )

  override fun createReactActivityLifecycleListeners(activityContext: Context?): List<ReactActivityLifecycleListener> =
    listOf(
      object : ReactActivityLifecycleListener {
        override fun onNewIntent(intent: Intent?): Boolean {
          if (!DevLauncherPackageDelegate.shouldEnableAutoSetup || intent == null || activityContext == null || activityContext !is ReactActivity) {
            return false
          }
          return DevLauncherController.tryToHandleIntent(activityContext, intent)
        }
      }
    )

  override fun createReactActivityHandlers(activityContext: Context?): List<ReactActivityHandler> =
    listOf(
      object : ReactActivityHandler {
        override fun onDidCreateReactActivityDelegate(activity: ReactActivity, delegate: ReactActivityDelegate): ReactActivityDelegate? {
          if (!DevLauncherPackageDelegate.shouldEnableAutoSetup) {
            return null
          }
          return DevLauncherController.wrapReactActivityDelegate(
            activity,
            object : DevLauncherReactActivityDelegateSupplier {
              override fun get(): ReactActivityDelegate {
                return delegate
              }
            }
          )
        }
      }
    )

  override fun createReactNativeHostHandlers(context: Context): List<ReactNativeHostHandler> =
    listOf(DevLauncherReactNativeHostHandler(context))
}
