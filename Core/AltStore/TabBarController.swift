//
//  TabBarController.swift
//  AltStore
//
//  Created by Riley Testut on 9/19/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

extension TabBarController
{
    private enum Tab: Int, CaseIterable
    {
        case news
        case sources
        case browse
        case myApps
        case settings
    }
}

final class TabBarController: UITabBarController
{
    private var initialSegue: (identifier: String, sender: Any?)?
    
    private var _viewDidAppear = false
    
    private var sourcesViewController: SourcesViewController!
    
    required init?(coder aDecoder: NSCoder)
    {
        super.init(coder: aDecoder)
        
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.importApp(_:)), name: AppDelegate.importAppDeepLinkNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.presentSources(_:)), name: AppDelegate.addSourceDeepLinkNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.openErrorLog(_:)), name: ToastView.openErrorLogNotification, object: nil)
    }
    
    override func viewDidLoad() 
    {
        super.viewDidLoad()
        debugLog("[TabBarController] viewDidLoad()")
        
        let browseNavigationController = self.viewControllers![Tab.browse.rawValue] as! UINavigationController
        browseNavigationController.tabBarItem.image = UIImage(systemName: "bag")
        
        let sourcesNavigationController = self.viewControllers![Tab.sources.rawValue] as! UINavigationController
        self.sourcesViewController = sourcesNavigationController.viewControllers.first as? SourcesViewController

        self.installBackToAnderStoreButtons()
    }
    
    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)
        debugLog("[TabBarController] viewDidAppear() — TabBarController is now visible")
        
        _viewDidAppear = true
        
        if let (identifier, sender) = self.initialSegue
        {
            self.initialSegue = nil
            self.performSegue(withIdentifier: identifier, sender: sender)
        }
    }
    
    override func performSegue(withIdentifier identifier: String, sender: Any?)
    {
        guard _viewDidAppear else {
            self.initialSegue = (identifier, sender)
            return
        }
        
        super.performSegue(withIdentifier: identifier, sender: sender)
    }
}

extension TabBarController
{
    @objc func presentSources(_ sender: Any)
    {
        if let presentedViewController = self.presentedViewController
        {
            presentedViewController.dismiss(animated: true) {
                self.presentSources(sender)
            }
            
            return
        }
                
        if let notification = (sender as? Notification), let sourceURL = notification.userInfo?[AppDelegate.addSourceDeepLinkURLKey] as? URL
        {
            self.sourcesViewController?.deepLinkSourceURL = sourceURL
        }
        
        self.selectedIndex = Tab.sources.rawValue
    }
}

private extension TabBarController
{
    @objc func importApp(_ notification: Notification)
    {
        self.selectedIndex = Tab.myApps.rawValue
    }

    @objc func openErrorLog(_ notification: Notification)
    {
        self.selectedIndex = Tab.settings.rawValue
    }
}

// MARK: - AnderStore: return from Core to the main AnderStore screen
extension TabBarController
{
    /// LCSharedUtils only exists when Core runs embedded inside AnderStore (LiveContainer host).
    private static var anderStoreHost: AnyClass? { NSClassFromString("LCSharedUtils") }

    fileprivate func installBackToAnderStoreButtons()
    {
        guard Self.anderStoreHost != nil else { return }

        for case let navigationController as UINavigationController in self.viewControllers ?? []
        {
            guard let rootViewController = navigationController.viewControllers.first,
                  rootViewController.navigationItem.leftBarButtonItem == nil
            else { continue }

            let button = UIBarButtonItem(title: "AnderStore", style: .plain, target: self, action: #selector(TabBarController.returnToAnderStore))
            button.image = UIImage(systemName: "chevron.backward")
            rootViewController.navigationItem.leftBarButtonItem = button
        }
    }

    @objc fileprivate func returnToAnderStore()
    {
        guard let host = Self.anderStoreHost, let metaclass = object_getClass(host) else { return }

        let selector = NSSelectorFromString("launchToGuestAppWithClassicMode:")
        guard class_respondsToSelector(metaclass, selector),
              let implementation = class_getMethodImplementation(metaclass, selector)
        else { return }

        typealias LaunchFunction = @convention(c) (AnyClass, Selector, UInt) -> Bool
        _ = unsafeBitCast(implementation, to: LaunchFunction.self)(host, selector, 0)
    }
}
