//
//  LGTools.m
//  AutoPkgr
//
//  Copyright 2015 Eldon Ahrold
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//
//

#import "LGTool.h"
#import "LGTool+Private.h"

#import "LGAutoPkgr.h"

#import "LGVersionComparator.h"
#import "LGInstaller.h"
#import "LGUninstaller.h"

#import "LGAutoPkgTask.h"
#import "LGHostInfo.h"

#ifndef LGTOOL_SUBCLASS
    #define LGTOOL_SUBCLASS
#endif

@interface LGTool ()
@property (copy, nonatomic, readwrite) LGToolInfo *info;
@end

@interface LGToolInfo ()
- (instancetype)initWithTool:(LGTool *)tool;
@end

void subclassMustImplement(id className, SEL _cmd)
{
    NSString *reason = [NSString stringWithFormat:@"Subclass of %s must implement the method \"%s\".",
                                                  object_getClassName(className), sel_getName(_cmd)];
    @throw [NSException exceptionWithName:@"SubclassMustImplement"
                                   reason:reason
                                 userInfo:nil];
}

@implementation LGTool {
    void (^_progressUpdateBlock)(NSString *, double);
    void (^_replyErrorBlock)(NSError *);
}

+ (BOOL)isInstalled
{
    if ((self.typeFlags & kLGToolTypeAutoPkgSharedProcessor) && (![self components])) {
        return [[LGAutoPkgTask repoList] containsObject:[self defaultRepository]];
    } else {
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *file in self.components) {
            if (![fm fileExistsAtPath:file]) {
                return NO;
            }
        }
    }
    return YES;
}

+ (BOOL)meetsRequirements:(NSError *__autoreleasing *)error
{
    return YES;
}

#pragma mark - Init / Dealloc
- (void)dealloc
{
    DevLog(@"Dealloc %@", self);

    // nil out the blocks to break retain cycles.
    self.infoUpdateHandler = nil;
    _progressUpdateBlock = nil;
    _replyErrorBlock = nil;
}

- (instancetype)init
{
    if (self = [super init]) {
        if ([[self class] typeFlags] & kLGToolTypeInstalledPackage) {
             _gitHubInfo = [[LGGitHubReleaseInfo alloc] initWithURL:[[self class]gitHubURL]];
        }
    }
    return self;
}

#pragma mark - Subclass responsibility

+ (NSString *)name
{
    subclassMustImplement(self, _cmd);
    return nil;
}

+ (LGToolTypeFlags)typeFlags
{
    subclassMustImplement(self, _cmd);
    return kLGToolTypeUnspecified;
}

+ (NSString *)binary
{
    if ([self typeFlags] & kLGToolTypeInstalledPackage) {
        subclassMustImplement(self, _cmd);
    }
    return nil;
}

+ (NSArray *)components
{
    if ([self typeFlags ] & kLGToolTypeInstalledPackage) {
        subclassMustImplement(self, _cmd);
    }
    return nil;
}

+ (NSString *)defaultRepository {
    if ([self typeFlags] & kLGToolTypeAutoPkgSharedProcessor) {
        subclassMustImplement(self, _cmd);
    }
    return nil;
}

+ (NSString *)gitHubURL
{
    if ([[self class] typeFlags ] & kLGToolTypeInstalledPackage) {
        subclassMustImplement(self, _cmd);
    }
    return nil;
}

+ (NSString *)packageIdentifier
{
    if ([[self class] typeFlags] & kLGToolTypeInstalledPackage) {
        subclassMustImplement(self, _cmd);
    }
    return nil;
}

- (void)customInstallActions {}
- (void)customUninstallActions {}

#pragma mark - Super implementation
- (void)getInfo:(void (^)(LGToolInfo *))complete;
{
    self.infoUpdateHandler = complete;
    [self refresh];
}

- (void)refresh;
{
    if (self.infoUpdateHandler) {
        LGGitHubJSONLoader *loader = [[LGGitHubJSONLoader alloc] initWithGitHubURL:[[self class] gitHubURL]];

        [loader getReleaseInfo:^(LGGitHubReleaseInfo *gitHubInfo, NSError *error) {
            self.gitHubInfo = gitHubInfo;
            _info = [[LGToolInfo alloc] initWithTool:self];
            self.infoUpdateHandler(_info);
        }];
    } else {
        _info = [[LGToolInfo alloc] initWithTool:self];
    }
}

- (LGToolInfo *)info
{
    if (!_info) {
        _info = [[LGToolInfo alloc] initWithTool:self];
    }
    return _info;
}

- (NSString *)remoteVersion
{
    if ([[self class]typeFlags] & kLGToolTypeInstalledPackage) {
        return self.gitHubInfo.latestVersion;
    }

    // For now shared processors don't report a version.
    // We could possibly use git to check for an update.
    return nil;
}

- (NSString *)installedVersion
{
    LGToolTypeFlags typeFlags = [[self class] typeFlags];

    if (typeFlags & kLGToolTypeInstalledPackage) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *packageReciept = [[@"/private/var/db/receipts/" stringByAppendingPathComponent:[[self class] packageIdentifier]] stringByAppendingPathExtension:@"plist"];

        if ([[self class] isInstalled]) {
            if ([fm fileExistsAtPath:packageReciept]) {
                NSDictionary *receiptDict = [NSDictionary dictionaryWithContentsOfFile:packageReciept];
                _installedVersion = receiptDict[@"PackageVersion"];
            }
        }
    } else if (typeFlags & kLGToolTypeAutoPkgSharedProcessor) {
        _installedVersion = @"Shared Processor";
    }

    return _installedVersion;
}

- (NSString *)downloadURL
{
    return self.gitHubInfo.latestReleaseDownload;
}

- (void)installPackage:(id)sender{
    NSString *name = [[self class] name];
    LGToolTypeFlags typeFlags = [[self class] typeFlags];

    NSString *installMessage = [NSString stringWithFormat:@"Installing %@...", [[self class] name]];
    [_progressDelegate startProgressWithMessage:installMessage];

    LGInstaller *installer = [[LGInstaller alloc] init];
    installer.downloadURL = self.downloadURL;
    installer.progressDelegate = _progressDelegate;

    [installer runInstaller:name reply:^(NSError *error) {

        if (!error && (typeFlags & kLGToolTypeAutoPkgSharedProcessor)) {
            [self installDefaultRepository:sender];
        } else {
            [self installComplete:sender error:error];
        }
    }];
}

- (void)installDefaultRepository:(id)sender {
    NSString *name = [[self class] name];
    [_progressDelegate startProgressWithMessage:[NSString stringWithFormat:@"Adding default AutoPkg repo for %@", name]];

    LGAutoPkgTask *task = [LGAutoPkgTask addRepoTask:[[self class] defaultRepository]];
    task.progressDelegate = _progressDelegate;
    [task launchInBackground:^(NSError *error) {
        [self installComplete:sender error:error];

        // Post a notification to trigger a reload of the repo table.
        [[NSNotificationCenter defaultCenter] postNotificationName:kLGNotificationReposModified
                                                            object:nil];

    }];
}

- (void)install:(id)sender
{
    // Disable the sender to prevent multiple signals
    if ([sender respondsToSelector:@selector(isEnabled)]) {
        [sender setEnabled:NO];
    }

    LGToolTypeFlags flags = [[self class] typeFlags];

    if (flags & kLGToolTypeInstalledPackage) {
        [self installPackage:sender];
    } else if (flags & kLGToolTypeAutoPkgSharedProcessor) {
        [self installDefaultRepository:sender];
    }
}

- (void)install:(void (^)(NSString *, double))progress reply:(void (^)(NSError *))reply
{
    if (progress) {
        _progressUpdateBlock = progress;
        _progressDelegate = self;
    }

    if (reply) {
        _replyErrorBlock = reply;
    }

    [self install:nil];
}

- (void)installComplete:(id)sender error:(NSError *)error {
    [_progressDelegate stopProgress:error];

    if ([sender respondsToSelector:@selector(isEnabled)]) {
        [sender setEnabled:YES];
    }

    if ([[self class] isInstalled] && [sender respondsToSelector:@selector(action)]) {
        [sender setAction:@selector(uninstall:)];
    }

    [self refresh];
}

- (void)uninstall:(void (^)(NSString *, double))progress reply:(void (^)(NSError *))reply
{
    _progressDelegate = self;
    if (progress) {
        _progressUpdateBlock = progress;
    }

    if (reply) {
        _replyErrorBlock = reply;
    }
}

- (void)uninstall:(id)sender
{
    // TODO: implement an uninstaller.
    if (![[self class] isInstalled] && [sender respondsToSelector:@selector(action)]) {
        [sender setAction:@selector(install:)];
    }
}

- (NSString *)versionTaskWithExec:(NSString *)exec arguments:(NSArray *)arguments
{
    NSString *installedVersion = nil;

    if ([[NSFileManager defaultManager] isExecutableFileAtPath:exec]) {
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = exec;
        task.arguments = arguments;
        task.standardOutput = [NSPipe pipe];

        [task launch];
        [task waitUntilExit];

        NSData *data = [[task.standardOutput fileHandleForReading] readDataToEndOfFile];
        if (data) {
            installedVersion = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
    }

    return installedVersion ?: @"";
}

- (NSError *)requirementsError:(NSString *)reason
{
    NSString *description = [NSString stringWithFormat:@"Requirements for %@ are not met.", [[self class] name]];
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey : description,
        NSLocalizedRecoverySuggestionErrorKey : reason ?: @"",
    };

    return [NSError errorWithDomain:kLGApplicationName code:-1 userInfo:userInfo];
}

#pragma mark - LGProgress Delegate
- (void)startProgressWithMessage:(NSString *)message
{
    // Not implemented
}

- (void)stopProgress:(NSError *)error
{
    if (_replyErrorBlock) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            _replyErrorBlock(error);
        }];
    }
}

- (void)updateProgress:(NSString *)message progress:(double)progress
{
    if (_progressUpdateBlock) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            _progressUpdateBlock(message, progress);
        }];
    }
}

- (void)bringAutoPkgrToFront
{
    // Not implemented
}

@end

#pragma mark - Tool Info Object
@implementation LGToolInfo {
    NSString *_name;
    LGToolTypeFlags _typeFlags;

    LGToolInstallStatus _status;
    BOOL _installed;
    NSString *_defaultRepo;

}

- (instancetype)initWithTool:(LGTool *)tool;
{
    if (self = [super init]) {
        _name = [[tool class] name];
        _typeFlags = [[tool class] typeFlags];
        _installed = [[tool class] isInstalled];
        _defaultRepo = [[tool class] defaultRepository];

        _remoteVersion = tool.remoteVersion;
        _installedVersion = tool.installedVersion;

    }

    return self;
}

- (LGToolInstallStatus)status
{
    _status = kLGToolUpToDate;

    if (!_installed || !_installedVersion) {
        _status = kLGToolNotInstalled;
    } else if (_installedVersion && _remoteVersion) {
        if ([LGVersionComparator isVersion:_remoteVersion greaterThanVersion:_installedVersion]) {
            _status = kLGToolUpdateAvailable;
        }
    }
    return _status;
}

#pragma mark - Mappings

- (NSImage *)statusImage
{
    NSImage *stausImage = nil;
    switch (self.status) {
    case kLGToolNotInstalled:
        stausImage = [NSImage LGStatusNotInstalled];
        break;
    case kLGToolUpdateAvailable:
        stausImage = [NSImage LGStatusUpdateAvailable];
        break;
    case kLGToolUpToDate:
    default:
        stausImage = [NSImage LGStatusUpToDate];
        break;
    }
    return stausImage;
}

- (NSString *)statusString
{
    NSString *statusString = @"";
    switch (self.status) {
    case kLGToolNotInstalled:
        statusString = [NSString stringWithFormat:@"%@ not installed.", _name];
        break;
    case kLGToolUpdateAvailable:
        statusString = [NSString stringWithFormat:@"%@ %@ update now available.", _name, self.remoteVersion];
        break;
    case kLGToolUpToDate:
    default:
        statusString = [NSString stringWithFormat:@"%@ %@ installed.", _name, self.installedVersion];
        break;
    }
    return statusString;
}

- (NSString *)installButtonTitle
{
    NSString *title;
    switch (self.status) {
        case kLGToolNotInstalled:
            title = @"Install ";
            break;
        case kLGToolUpdateAvailable:
            title = @"Update ";
            break;
        case kLGToolUpToDate:
            title = @"Uninstall ";
            break;
        default:
            break;
    }
    return [title stringByAppendingString:_name];
}

- (BOOL)needsInstalled
{
    switch (self.status) {
    case kLGToolNotInstalled:
    case kLGToolUpdateAvailable:
        return YES;
    case kLGToolUpToDate:
    default:
        return NO;
    }
}

@end
