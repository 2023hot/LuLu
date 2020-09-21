//
//  file: utilities.m
//  project: lulu (shared)
//  description: various helper/utility functions
//
//  created by Patrick Wardle
//  copyright (c) 2017 Objective-See. All rights reserved.
//

#import "consts.h"
#import "utilities.h"

@import Sentry;

@import OSLog;
@import Carbon;
@import Security;
@import Foundation;
@import CommonCrypto;
@import SystemConfiguration;

#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>
#import <libproc.h>
#import <sys/stat.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <sys/sysctl.h>

/* GLOBALS */

//log handle
extern os_log_t logHandle;

//init crash reporting
void initCrashReporting()
{
    //sentry
    NSBundle *sentry = nil;
    
    //error
    NSError* error = nil;
    
    //class
    Class SentryClient = nil;
    
    //load senty
    sentry = loadFramework(@"Sentry.framework");
    if(nil == sentry)
    {
        //err msg
        os_log_error(logHandle, "ERROR: failed to load 'Sentry' framework");
        
        //bail
        goto bail;
    }
   
    //get client class
    SentryClient = NSClassFromString(@"SentryClient");
    if(nil == SentryClient)
    {
        //bail
        goto bail;
    }
    
    //set shared client
    [SentryClient setSharedClient:[[SentryClient alloc] initWithDsn:CRASH_REPORTING_URL didFailWithError:&error]];
    if(nil != error)
    {
        //err msg
        os_log_error(logHandle, "ERROR: initializing 'Sentry' failed with %{public}@", error);
        
        //bail
        goto bail;
    }
    
    //start crash handler
    [[SentryClient sharedClient] startCrashHandlerWithError:&error];
    if(nil != error)
    {
        //err msg
        os_log_error(logHandle, "ERROR: starting 'Sentry' crash handler failed with %{public}@", error);
        
        //bail
        goto bail;
    }

bail:
    
    return;
}

//get app's version
// extracted from Info.plist
NSString* getAppVersion()
{
    //read and return 'CFBundleVersion' from bundle
    return [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"];
}


//give path to app
// get full path to its binary
NSString* getAppBinary(NSString* appPath)
{
    //binary path
    NSString* binaryPath = nil;
    
    //app bundle
    NSBundle* appBundle = nil;
    
    //load app bundle
    appBundle = [NSBundle bundleWithPath:appPath];
    if(nil == appBundle)
    {
        //err msg
        os_log_error(logHandle, "failed to load app bundle for %{public}@", appPath);
        
        //bail
        goto bail;
    }
    
    //extract executable
    binaryPath = [appBundle.executablePath stringByResolvingSymlinksInPath];
    
bail:
    
    return binaryPath;
}

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

//get (true) parent
NSDictionary* getRealParent(pid_t pid)
{
    //process info
    NSDictionary* processInfo = nil;
    
    //process serial number
    ProcessSerialNumber psn = {0, kNoProcess};
    
    //(parent) process serial number
    ProcessSerialNumber ppsn = {0, kNoProcess};
    
    //get process serial number from pid
    if(noErr != GetProcessForPID(pid, &psn))
    {
        //err
        goto bail;
    }
    
    //get process (carbon) info
    processInfo = CFBridgingRelease(ProcessInformationCopyDictionary(&psn, (UInt32)kProcessDictionaryIncludeAllInformationMask));
    if(nil == processInfo)
    {
        //err
        goto bail;
    }
    
    //extract/convert parent ppsn
    ppsn.lowLongOfPSN =  [processInfo[@"ParentPSN"] longLongValue] & 0x00000000FFFFFFFFLL;
    ppsn.highLongOfPSN = ([processInfo[@"ParentPSN"] longLongValue] >> 32) & 0x00000000FFFFFFFFLL;
    
    //get parent process (carbon) info
    processInfo = CFBridgingRelease(ProcessInformationCopyDictionary(&ppsn, (UInt32)kProcessDictionaryIncludeAllInformationMask));
    if(nil == processInfo)
    {
        //err
        goto bail;
    }
    
bail:
    
    return processInfo;
}

#pragma GCC diagnostic pop

//get name of logged in user
NSString* getConsoleUser()
{
    //copy/return user
    return CFBridgingRelease(SCDynamicStoreCopyConsoleUser(NULL, NULL, NULL));
}

//get process name
// either via app bundle, or path
NSString* getProcessName(NSString* path)
{
    //process name
    NSString* processName = nil;
    
    //app bundle
    NSBundle* appBundle = nil;
    
    //try find an app bundle
    appBundle = findAppBundle(path);
    if(nil != appBundle)
    {
        //grab name from app's bundle
        processName = [appBundle infoDictionary][@"CFBundleName"];
    }
    
    //still nil?
    // just grab from path
    if(nil == processName)
    {
        //from path
        processName = [path lastPathComponent];
    }
    
    return processName;
}

//given a path to binary
// parse it back up to find app's bundle
NSBundle* findAppBundle(NSString* path)
{
    //app's bundle
    NSBundle* appBundle = nil;
    
    //app's path
    NSString* appPath = nil;
    
    //first just try full path
    appPath = [[path stringByResolvingSymlinksInPath] stringByStandardizingPath];
    
    //try to find the app's bundle/info dictionary
    do
    {
        //try to load app's bundle
        appBundle = [NSBundle bundleWithPath:appPath];
        
        //was an app passed in?
        if(YES == [appBundle.bundlePath isEqualToString:path])
        {
            //all done
            break;
        }
        
        //check for match
        // ->binary path's match
        if( (nil != appBundle) &&
            (YES == [appBundle.executablePath isEqualToString:path]))
        {
            //all done
            break;
        }
        
        //always unset bundle var since it's being returned
        // ->and at this point, its not a match
        appBundle = nil;
        
        //remove last part
        // ->will try this next
        appPath = [appPath stringByDeletingLastPathComponent];
        
    //scan until we get to root
    // of course, loop will exit if app info dictionary is found/loaded
    } while( (nil != appPath) &&
             (YES != [appPath isEqualToString:@"/"]) &&
             (YES != [appPath isEqualToString:@""]) );
    
    return appBundle;
}

//get process's path
NSString* getProcessPath(pid_t pid)
{
    //task path
    NSString* processPath = nil;
    
    //buffer for process path
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    
    //status
    int status = -1;
    
    //'management info base' array
    int mib[3] = {0};
    
    //system's size for max args
    unsigned long systemMaxArgs = 0;
    
    //process's args
    char* taskArgs = NULL;
    
    //# of args
    int numberOfArgs = 0;
    
    //size of buffers, etc
    size_t size = 0;
    
    //reset buffer
    memset(pathBuffer, 0x0, PROC_PIDPATHINFO_MAXSIZE);
    
    //first attempt to get path via 'proc_pidpath()'
    status = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
    if(0 != status)
    {
        //init task's name
        processPath = [NSString stringWithUTF8String:pathBuffer];
    }
    //otherwise
    // try via task's args ('KERN_PROCARGS2')
    else
    {
        //init mib
        // want system's size for max args
        mib[0] = CTL_KERN;
        mib[1] = KERN_ARGMAX;
        
        //set size
        size = sizeof(systemMaxArgs);
        
        //get system's size for max args
        if(-1 == sysctl(mib, 2, &systemMaxArgs, &size, NULL, 0))
        {
            //bail
            goto bail;
        }
        
        //alloc space for args
        taskArgs = malloc(systemMaxArgs);
        if(NULL == taskArgs)
        {
            //bail
            goto bail;
        }
        
        //init mib
        // want process args
        mib[0] = CTL_KERN;
        mib[1] = KERN_PROCARGS2;
        mib[2] = pid;
        
        //set size
        size = (size_t)systemMaxArgs;
        
        //get process's args
        if(-1 == sysctl(mib, 3, taskArgs, &size, NULL, 0))
        {
            //bail
            goto bail;
        }
        
        //sanity check
        // ensure buffer is somewhat sane
        if(size <= sizeof(int))
        {
            //bail
            goto bail;
        }
        
        //extract number of args
        memcpy(&numberOfArgs, taskArgs, sizeof(numberOfArgs));
        
        //extract task's name
        // follows # of args (int) and is NULL-terminated
        processPath = [NSString stringWithUTF8String:taskArgs + sizeof(int)];
    }
    
bail:
    
    //free process args
    if(NULL != taskArgs)
    {
        //free
        free(taskArgs);
        
        //reset
        taskArgs = NULL;
    }
    
    return processPath;
}

//given a process path and user
// return array of all matching pids
NSMutableArray* getProcessIDs(NSString* processPath, int userID)
{
    //status
    int status = -1;
    
    //process IDs
    NSMutableArray* processIDs = nil;
    
    //# of procs
    int numberOfProcesses = 0;
        
    //array of pids
    pid_t* pids = NULL;
    
    //process info struct
    struct kinfo_proc procInfo = {0};
    
    //size of struct
    size_t procInfoSize = sizeof(procInfo);
    
    //mib
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, -1};
    
    //clear buffer
    memset(&procInfo, 0x0, procInfoSize);
    
    //get # of procs
    numberOfProcesses = proc_listallpids(NULL, 0);
    if(-1 == numberOfProcesses)
    {
        //bail
        goto bail;
    }
    
    //alloc buffer for pids
    pids = calloc((unsigned long)numberOfProcesses, sizeof(pid_t));
    
    //alloc
    processIDs = [NSMutableArray array];
    
    //get list of pids
    status = proc_listallpids(pids, numberOfProcesses * (int)sizeof(pid_t));
    if(status < 0)
    {
        //bail
        goto bail;
    }
        
    //iterate over all pids
    // get name for each process
    for(int i = 0; i < (int)numberOfProcesses; i++)
    {
        //skip blank pids
        if(0 == pids[i])
        {
            //skip
            continue;
        }
        
        //skip if path doesn't match
        if(YES != [processPath isEqualToString:getProcessPath(pids[i])])
        {
            //next
            continue;
        }
        
        //need to also match on user?
        // caller can pass in -1 to skip this check
        if(-1 != userID)
        {
            //init mib
            mib[0x3] = pids[i];
            
            //make syscall to get proc info for user
            if( (0 != sysctl(mib, 0x4, &procInfo, &procInfoSize, NULL, 0)) ||
                (0 == procInfoSize) )
            {
                //skip
                continue;
            }

            //skip if user id doesn't match
            if(userID != (int)procInfo.kp_eproc.e_ucred.cr_uid)
            {
                //skip
                continue;
            }
        }
        
        //got match
        // add to list
        [processIDs addObject:[NSNumber numberWithInt:pids[i]]];
    }
    
bail:
        
    //free buffer
    if(NULL != pids)
    {
        //free
        free(pids);
        
        //reset
        pids = NULL;
    }
    
    return processIDs;
}

//enable/disable a menu
void toggleMenu(NSMenu* menu, BOOL shouldEnable)
{
    //disable autoenable
    menu.autoenablesItems = NO;
    
    //iterate over
    // set state of each item
    for(NSMenuItem* item in menu.itemArray)
    {
        //set state
        item.enabled = shouldEnable;
    }
    
    return;
}

//get an icon for a process
// for apps, this will be app's icon, otherwise just a standard system one
NSImage* getIconForProcess(NSString* path)
{
    //icon's file name
    NSString* iconFile = nil;
    
    //icon's path
    NSString* iconPath = nil;
    
    //icon's path extension
    NSString* iconExtension = nil;
    
    //icon
    NSImage* icon = nil;
    
    //system's document icon
    static NSImage* documentIcon = nil;
    
    //bundle
    NSBundle* appBundle = nil;
    
    //invalid path?
    // grab a default icon and bail
    if(YES != [[NSFileManager defaultManager] fileExistsAtPath:path])
    {
        //set icon to system 'application' icon
        icon = [[NSWorkspace sharedWorkspace]
                iconForFileType: NSFileTypeForHFSTypeCode(kGenericApplicationIcon)];
        
        //set size to 64 @2x
        [icon setSize:NSMakeSize(128, 128)];
   
        //bail
        goto bail;
    }
    
    //first try grab bundle
    // then extact icon from this
    appBundle = findAppBundle(path);
    if(nil != appBundle)
    {
        //get file
        iconFile = appBundle.infoDictionary[@"CFBundleIconFile"];
        
        //get path extension
        iconExtension = [iconFile pathExtension];
        
        //if its blank (i.e. not specified)
        // go with 'icns'
        if(YES == [iconExtension isEqualTo:@""])
        {
            //set type
            iconExtension = @"icns";
        }
        
        //set full path
        iconPath = [appBundle pathForResource:[iconFile stringByDeletingPathExtension] ofType:iconExtension];
        
        //load it
        icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
    }
    
    //process is not an app or couldn't get icon
    // try to get it via shared workspace
    if( (nil == appBundle) ||
        (nil == icon) )
    {
        //extract icon
        icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
        
        //load system document icon
        // static var, so only load once
        if(nil == documentIcon)
        {
            //load
            documentIcon = [[NSWorkspace sharedWorkspace] iconForFileType:
                            NSFileTypeForHFSTypeCode(kGenericDocumentIcon)];
        }
        
        //if 'iconForFile' method doesn't find and icon, it returns the system 'document' icon
        // the system 'application' icon seems more applicable, so use that here...
        if(YES == [icon isEqual:documentIcon])
        {
            //set icon to system 'application' icon
            icon = [[NSWorkspace sharedWorkspace]
                    iconForFileType: NSFileTypeForHFSTypeCode(kGenericApplicationIcon)];
        }
        
        //'iconForFileType' returns small icons
        // so set size to 64 @2x
        [icon setSize:NSMakeSize(128, 128)];
    }
    
bail:
    
    return icon;
}

//wait till window non-nil
// then make that window modal
void makeModal(NSWindowController* windowController)
{
    //window
    __block NSWindow* window = nil;
    
    //wait till non-nil
    // then make window modal
    for(int i=0; i<20; i++)
    {
        //grab window
        dispatch_sync(dispatch_get_main_queue(), ^{
         
            //grab
            window = windowController.window;
            
        });
                      
        //nil?
        // nap
        if(nil == window)
        {
            //nap
            [NSThread sleepForTimeInterval:0.05f];
            
            //next
            continue;
        }
        
        //have window?
        // make it modal
        dispatch_sync(dispatch_get_main_queue(), ^{
            
            //modal
            [[NSApplication sharedApplication] runModalForWindow:windowController.window];
            
        });
        
        //done
        break;
    }
    
    return;
}

//find a process by name
pid_t findProcess(NSString* processName)
{
    //pid
    pid_t pid = -1;
    
    //status
    int status = -1;
    
    //# of procs
    int numberOfProcesses = 0;
    
    //array of pids
    pid_t* pids = NULL;
    
    //process path
    NSString* processPath = nil;
    
    //get # of procs
    numberOfProcesses = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if(-1 == numberOfProcesses)
    {
        //bail
        goto bail;
    }
    
    //alloc buffer for pids
    pids = calloc((unsigned long)numberOfProcesses, sizeof(pid_t));
    
    //get list of pids
    status = proc_listpids(PROC_ALL_PIDS, 0, pids, numberOfProcesses * (int)sizeof(pid_t));
    if(status < 0)
    {
        //bail
        goto bail;
    }
    
    //iterate over all pids
    // get name for each via helper function
    for(int i = 0; i < numberOfProcesses; ++i)
    {
        //skip blank pids
        if(0 == pids[i])
        {
            //skip
            continue;
        }
        
        //get path
        processPath = getProcessPath(pids[i]);
        if( (nil == processPath) ||
            (0 == processPath.length) )
        {
            //skip
            continue;
        }
        
        //no match?
        if(YES != [processPath.lastPathComponent isEqualToString:processName])
        {
            //skip
            continue;
        }
            
        //save
        pid = pids[i];
        
        //pau
        break;
        
    }//all procs
    
bail:
    
    //free buffer
    if(NULL != pids)
    {
        //free
        free(pids);
        pids = NULL;
    }
    
    return pid;
}

//for login item enable/disable
// we use the launch services APIs, since replacements don't always work :(
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

//toggle login item
// either add (install) or remove (uninstall)
BOOL toggleLoginItem(NSURL* loginItem, int toggleFlag)
{
    //flag
    BOOL wasToggled = NO;
    
    //login item ref
    LSSharedFileListRef loginItemsRef = NULL;
    
    //login items
    CFArrayRef loginItems = NULL;
    
    //current login item
    CFURLRef currentLoginItem = NULL;
    
    //get reference to login items
    loginItemsRef = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    
    //add (install)
    if(ACTION_INSTALL_FLAG == toggleFlag)
    {
        //dbg msg
        os_log_debug(logHandle, "adding login item: %{public}@", loginItem.path);
        
        //add
        LSSharedFileListItemRef itemRef = LSSharedFileListInsertItemURL(loginItemsRef, kLSSharedFileListItemLast, NULL, NULL, (__bridge CFURLRef)(loginItem), NULL, NULL);
        
        //release item ref
        if(NULL != itemRef)
        {
            //dbg msg
            os_log_debug(logHandle, "added %{public}@/%{public}@", loginItem, itemRef);
            
            //release
            CFRelease(itemRef);
            
            //reset
            itemRef = NULL;
        }
        //failed
        else
        {
            //err msg
            os_log_error(logHandle, "ERROR: failed to add login item");
            
            //bail
            goto bail;
        }
        
        //happy
        wasToggled = YES;
    }
    //remove (uninstall)
    else
    {
        //dbg msg
        os_log_debug(logHandle, "removing login item, %{public}@", loginItem.path);
        
        //grab existing login items
        loginItems = LSSharedFileListCopySnapshot(loginItemsRef, nil);
        
        //iterate over all login items
        // look for self(s), then remove it
        for(id item in (__bridge NSArray *)loginItems)
        {
            //get current login item
            currentLoginItem = LSSharedFileListItemCopyResolvedURL((__bridge LSSharedFileListItemRef)item, 0, NULL);
            if(NULL == currentLoginItem)
            {
                //skip
                continue;
            }
            
            //current login item match self?
            if(YES == [(__bridge NSURL *)currentLoginItem isEqual:loginItem])
            {
                //remove
                if(noErr == LSSharedFileListItemRemove(loginItemsRef, (__bridge LSSharedFileListItemRef)item))
                {
                    //dbg msg
                    os_log_debug(logHandle, "removed login item");
                    
                    //happy
                    wasToggled = YES;
                }
                else
                {
                    //err msg
                    os_log_error(logHandle, "ERROR: failed to remove login item");
                    
                    //keep trying though
                    // as might be multiple instances...
                }
            }
            
            //release
            CFRelease(currentLoginItem);
            
            //reset
            currentLoginItem = NULL;
            
        }//all login items
        
    }//remove/uninstall
    
bail:
    
    //release login items
    if(NULL != loginItems)
    {
        //release
        CFRelease(loginItems);
        
        //reset
        loginItems = NULL;
    }
    
    //release login ref
    if(NULL != loginItemsRef)
    {
        //release
        CFRelease(loginItemsRef);
        
        //reset
        loginItemsRef = NULL;
    }
    
    return wasToggled;
}

//grab date added
// extracted via 'kMDItemDateAdded'
NSDate* dateAdded(NSString* file)
{
    //date added
    NSDate* date = nil;
    
    //item
    MDItemRef item = NULL;
    
    //attribute names
    CFArrayRef attributeNames = NULL;
    
    //attributes
    CFDictionaryRef attributes = NULL;
    
    //app bundle
    NSBundle* appBundle = nil;
    
    //dbg msg
    os_log_debug(logHandle, "extracting 'kMDItemDateAdded' for %{public}@", file);
    
    //try find an app bundle
    appBundle = findAppBundle(file);
    if(nil == appBundle)
    {
        //dbg msg
        os_log_debug(logHandle, "no app bundle found for %{public}@", file);
        
        //bail
        goto bail;
    }
    
    //create item reference
    item = MDItemCreateWithURL(NULL, (__bridge CFURLRef)appBundle.bundleURL);
    if(NULL == item) goto bail;
    
    //get attribute names
    attributeNames = MDItemCopyAttributeNames(item);
    if(NULL == attributeNames) goto bail;
    
    //get attributes
    attributes = MDItemCopyAttributes(item, attributeNames);
    if(NULL == attributes) goto bail;
    
    //grab date added
    date = CFBridgingRelease(MDItemCopyAttribute(item, kMDItemDateAdded));
    
    //dbg msg
    os_log_debug(logHandle, "kMDItemDateAdded: %{public}@", date);

bail:
    
    //free attributes
    if(NULL != attributes) CFRelease(attributes);
    
    //free attribute names
    if(NULL != attributeNames) CFRelease(attributeNames);
    
    //free item
    if(NULL != item) CFRelease(item);
    
    return date;
    
}

#pragma clang diagnostic pop

//hash a file
NSMutableString* hashFile(NSString* filePath)
{
    //file's contents
    NSData* fileContents = nil;
    
    //hash digest
    uint8_t digestSHA256[CC_SHA256_DIGEST_LENGTH] = {0};
    
    //hash as string
    NSMutableString* sha256 = nil;
    
    //index var
    NSUInteger index = 0;
    
    //init
    sha256 = [NSMutableString string];
    
    //load file
    if(nil == (fileContents = [NSData dataWithContentsOfFile:filePath]))
    {
        //bail
        goto bail;
    }
    
    //sha256 it
    CC_SHA256(fileContents.bytes, (unsigned int)fileContents.length, digestSHA256);
    
    //convert to NSString
    // iterate over each bytes in computed digest and format
    for(index=0; index < CC_SHA256_DIGEST_LENGTH; index++)
    {
        //format/append
        [sha256 appendFormat:@"%02lX", (unsigned long)digestSHA256[index]];
    }
    
bail:
    
    return sha256;
}

//get parent pid
pid_t getParent(int pid)
{
    //parent id
    pid_t parentID = -1;
    
    //kinfo_proc struct
    struct kinfo_proc processStruct;
    
    //size
    size_t procBufferSize = sizeof(processStruct);
    
    //mib
    const u_int mibLength = 4;
    
    //syscall result
    int sysctlResult = -1;
    
    //init mib
    int mib[mibLength] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    
    //clear buffer
    memset(&processStruct, 0x0, procBufferSize);
    
    //make syscall
    sysctlResult = sysctl(mib, mibLength, &processStruct, &procBufferSize, NULL, 0);
    
    //check if got ppid
    if( (noErr == sysctlResult) &&
        (0 != procBufferSize) )
    {
        //save ppid
        parentID = processStruct.kp_eproc.e_ppid;
        
        //dbg msg
        os_log_debug(logHandle, "extracted parent ID %d for process: %d", parentID, pid);
    }
    
    return parentID;
}


//loads a framework
// note: assumes it is in 'Framework' dir
NSBundle* loadFramework(NSString* name)
{
    //handle
    NSBundle* framework = nil;
    
    //framework path
    NSString* path = nil;
    
    //init path
    path = [NSString stringWithFormat:@"%@/../Frameworks/%@", [NSProcessInfo.processInfo.arguments.firstObject stringByDeletingLastPathComponent], name];
    
    //standardize path
    path = [path stringByStandardizingPath];
    
    //init framework (bundle)
    framework = [NSBundle bundleWithPath:path];
    if(NULL == framework)
    {
        //bail
        goto bail;
    }
    
    //load framework
    if(YES != [framework loadAndReturnError:nil])
    {
        //bail
        goto bail;
    }
    
bail:
    
    return framework;
}

//dark mode?
BOOL isDarkMode()
{
    //check 'AppleInterfaceStyle'
    return [[[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"] isEqualToString:@"Dark"];
}

//check if something is nil
// if so, return a default ('unknown') value
NSString* valueForStringItem(NSString* item)
{
    return (nil != item) ? item : @"unknown";
}

//show an alert
NSModalResponse showAlert(NSString* messageText, NSString* informativeText)
{
    //alert
    NSAlert* alert = nil;
    
    //response
    NSModalResponse response = 0;
    
    //init alert
    alert = [[NSAlert alloc] init];
    
    //set style
    alert.alertStyle = NSAlertStyleWarning;
    
    //main text
    alert.messageText = messageText;
    
    //details
    alert.informativeText = informativeText;
    
    //add button
    [alert addButtonWithTitle:@"OK"];
    
    //make app active
    [NSApp activateIgnoringOtherApps:YES];
    
    //show
    response = [alert runModal];
    
    return response;
}