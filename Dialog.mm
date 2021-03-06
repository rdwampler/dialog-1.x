#import <Carbon/Carbon.h>
#import <string>
#import <sys/stat.h>
#import "Dialog.h"
#import "TMDSemaphore.h"
#import "TMDChameleon.h"


// Apple ought to document this <rdar://4821265>
@interface NSMethodSignature (Undocumented)
+(NSMethodSignature*)signatureWithObjCTypes:(const char*)types;
@end

@interface Dialog : NSObject <TextMateDialogServerProtocol>
{
}
- (id)initWithPlugInController:(id <TMPlugInController>)aController;
@end

@interface TMDWindowController : NSObject <NSWindowDelegate>
{
	NSWindow* window;
	BOOL isModal;
	BOOL center;
	BOOL async;
//	BOOL didLock;
	BOOL didCleanup;
	int	token;
}

// Fetch an existing controller
+ (TMDWindowController*)windowControllerForToken:(int)token;
+ (NSArray*)nibDescriptions;
- (void)cleanupAndRelease:(id)sender;

// return unique ID for this TMDWindowController instance
- (int)token;
- (NSString*)windowTitle;
- (void)setWindow:(NSWindow*)aWindow;
- (BOOL)isAsync;
- (void)wakeClient;
- (NSMutableDictionary*)returnResult;
@end

@interface TMDNibWindowController : TMDWindowController
{
	NSMutableDictionary* parameters;
	NSMutableArray* topLevelObjects;
}

- (id)initWithParameters:(NSMutableDictionary*)someParameters modal:(BOOL)flag center:(BOOL)shouldCenter aysnc:(BOOL)inAsync;
- (NSDictionary*)instantiateNib:(NSNib*)aNib;
- (void)updateParameters:(NSMutableDictionary *)params;

- (void)wakeClient;
- (void)makeControllersCommitEditing;
@end

@implementation TMDNibWindowController
- (id)initWithParameters:(NSMutableDictionary*)someParameters modal:(BOOL)flag center:(BOOL)shouldCenter aysnc:(BOOL)inAsync
{
	if(self = [super init])
	{
		parameters = [someParameters retain];
		[parameters setObject:self forKey:@"controller"];
		isModal = flag;
		center = shouldCenter;
		async = inAsync;
	}
	return self;
}

// Return the result; if there is no result, return the parameters
- (NSMutableDictionary *)returnResult
{
	id result = nil;
	
	if(async)
	{
		// Async dialogs return just the results
		result = [parameters objectForKey:@"result"];
		[[result retain] autorelease];
		[parameters removeObjectForKey:@"result"];
		
		if(result == nil )
		{
			result = [[parameters mutableCopy] autorelease];
		}
	}
	else
	{
		// Other dialogs return everything
		result = [[parameters mutableCopy] autorelease];
	}

	[result removeObjectForKey:@"controller"];
	
	return result;
}

- (void)makeControllersCommitEditing
{
	for(id object in topLevelObjects)
	{
		if([object respondsToSelector:@selector(commitEditing)])
			[object commitEditing];
	}

	[[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)cleanupAndRelease:(id)sender
{
	if(didCleanup)
		return;

	[parameters removeObjectForKey:@"controller"];
	[self makeControllersCommitEditing];

	// if we do not manually unbind, the object in the nib will keep us retained, and thus we will never reach dealloc
	for(id object in topLevelObjects)
	{
		if([object isKindOfClass:[NSObjectController class]])
			[object unbind:@"contentObject"];
	}

	[super cleanupAndRelease:sender];
}

- (void)performButtonClick:(id)sender
{
	if([sender respondsToSelector:@selector(title)])
		[parameters setObject:[sender title] forKey:@"returnButton"];
	if([sender respondsToSelector:@selector(tag)])
		[parameters setObject:[NSNumber numberWithInt:[sender tag]] forKey:@"returnCode"];
	
	[self wakeClient];
}

// returnArgument: implementation. See <http://lists.macromates.com/pipermail/textmate/2006-November/015321.html>
- (NSMethodSignature*)methodSignatureForSelector:(SEL)aSelector
{
	NSString* str = NSStringFromSelector(aSelector);
	if([str hasPrefix:@"returnArgument:"])
	{
		std::string types;
		types += @encode(void);
		types += @encode(id);
		types += @encode(SEL);
	
		unsigned numberOfArgs = [[str componentsSeparatedByString:@":"] count];
		while(numberOfArgs-- > 1)
			types += @encode(id);
	
		return [NSMethodSignature signatureWithObjCTypes:types.c_str()];
	}
	return [super methodSignatureForSelector:aSelector];
}

// returnArgument: implementation. See <http://lists.macromates.com/pipermail/textmate/2006-November/015321.html>
- (void)forwardInvocation:(NSInvocation*)invocation
{
	NSString* str = NSStringFromSelector([invocation selector]);
	if([str hasPrefix:@"returnArgument:"])
	{
		NSArray* argNames = [str componentsSeparatedByString:@":"];

		NSMutableDictionary* dict = [NSMutableDictionary dictionary];
		for(size_t i = 2; i < [[invocation methodSignature] numberOfArguments]; ++i)
		{
			id arg = nil;
			[invocation getArgument:&arg atIndex:i];
			[dict setObject:(arg ?: @"") forKey:[argNames objectAtIndex:i - 2]];
		}
		[parameters setObject:dict forKey:@"result"];
		
		// unblock the connection thread
		[self wakeClient];
	}
	else
	{
		[super forwardInvocation:invocation];
	}
}

- (NSDictionary*)instantiateNib:(NSNib*)aNib
{
	if(not async)
	{
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(connectionDidDie:) name:NSPortDidBecomeInvalidNotification object:nil];
	}

	BOOL didInstantiate = NO;
	@try {
	 	didInstantiate = [aNib instantiateNibWithOwner:self topLevelObjects:&topLevelObjects];
	}
	@catch(NSException* e) {
		// our retain count is too high if we reach this branch (<rdar://4803521>) so no RAII idioms for Cocoa, which is why we have the didLock variable, etc.
		NSLog(@"%s failed to instantiate nib (%@)", sel_getName(_cmd), [e reason]);
	}

	[topLevelObjects retain];
	for(id object in topLevelObjects)
	{
		if([object isKindOfClass:[NSWindow class]])
			[self setWindow:object];
	}
	
	if(window)
	{
		if(center)
		{
			if(NSWindow* keyWindow = [NSApp keyWindow])
			{
				NSRect frame = [window frame], parentFrame = [keyWindow frame];
				[window setFrame:NSMakeRect(NSMidX(parentFrame) - 0.5 * NSWidth(frame), NSMidY(parentFrame) - 0.5 * NSHeight(frame), NSWidth(frame), NSHeight(frame)) display:NO];
			}
			else
			{
				[window center];
			}
		}

		if(window != nil)
		{
			// Show the window
			[window makeKeyAndOrderFront:self];

			// TODO: When TextMate is capable of running script I/O in it's own thread(s), modal blocking
			// can go away altogether.
			if(isModal && window)
			{
				[NSApp runModalForWindow:window];
//				[self cleanupAndRelease:self];
			}
		}
	}
	else
	{
		NSLog(@"%s didn't find a window in nib", sel_getName(_cmd));
		[self cleanupAndRelease:self];
	}

	return parameters;
}

// Async param updates
- (void)updateParameters:(NSMutableDictionary *)updatedParams
{
	NSArray *	keys = [updatedParams allKeys];

	for(id key in keys)
	{
		[parameters setValue:[updatedParams valueForKey:key] forKey:key];
	}
}

- (void)dealloc
{
//	NSLog(@"%s %@ %d", sel_getName(_cmd), self, token);
	
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	for(id object in topLevelObjects)
		[object release];
	[topLevelObjects release];
	[parameters release];
	[super dealloc];
}

- (void)wakeClient
{
	// makeControllersCommitEditing can only be in this (sub) class, since it needs access to topLevelObjects, but wakeClient is the logical place for committing the UI values, yet that is defined in our super class
	[self makeControllersCommitEditing];
	[super wakeClient];
}
@end



@implementation TMDWindowController

static NSMutableArray *	sWindowControllers	= nil;
static int sNextWindowControllerToken = 1;

+ (NSArray*)nibDescriptions
{
	NSMutableArray*	outNibArray = [NSMutableArray array];
	
	for(TMDWindowController* windowController in sWindowControllers)
	{
//		if( [windowController isAsync] )
		{
			NSMutableDictionary*	nibDict = [NSMutableDictionary dictionary];
			NSString*				nibTitle = [windowController windowTitle];
			
			[nibDict setObject:[NSNumber numberWithInt:[windowController token]] forKey:@"token"];
			if(nibTitle != nil)
			{
				[nibDict setObject:nibTitle forKey:@"windowTitle"];
			}
			[outNibArray addObject:nibDict];
		}
	}
	
	return outNibArray;
}

+ (TMDWindowController*)windowControllerForToken:(int)token
{
	TMDWindowController*	outLoader = nil;
	
	for(TMDWindowController* loader in sWindowControllers)
	{
		if([loader token] == token)
		{
			outLoader = loader;
			break;
		}
	}

	return outLoader;
}

- (id)init
{
	if(self = [super init])
	{
		if(sWindowControllers == nil)
			sWindowControllers = [[NSMutableArray alloc] init];

		token = sNextWindowControllerToken;
		sNextWindowControllerToken += 1;
		
		[sWindowControllers addObject:self];
	}
	return self;
}

// Return the result; if there is no result, return the parameters
- (NSMutableDictionary *)returnResult
{
	// override me
	return nil;
}

- (void)dealloc
{
//	NSLog(@"%s %@ %d", sel_getName(_cmd), self, token);
	
	[[NSNotificationCenter defaultCenter] removeObserver:self];	
	[super dealloc];
}

- (BOOL)isAsync
{
	return async;
}

- (int)token
{
	return token;
}

- (NSString*)windowTitle
{
	return [window title];
}

- (void)wakeClient
{
	if(isModal)
		[NSApp stopModal];

	// Post dummy event; the event system sometimes stalls unless we do this after stopModal. See also connectionDidDie: in this file.
	[NSApp postEvent:[NSEvent otherEventWithType:NSApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0.0f windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
	
	TMDSemaphore *	semaphore = [TMDSemaphore semaphoreForTokenInt:token];
	[semaphore stopWaiting];
}

- (void)setWindow:(NSWindow*)aWindow
{
	if(window != aWindow)
	{
		[window setDelegate:nil];
		[window release];
		window = [aWindow retain];
		[window setDelegate:self];
		
		// We own the window, and we will release it. This prevents a potential crash later on.
		if([window isReleasedWhenClosed])
		{
			NSLog(@"warning: Window (%@) should not have released-when-closed bit set. I will clear it for you, but this it crash earlier versions of TextMate.", [window title]);
			[window setReleasedWhenClosed:NO];
		}
	}
}

- (void)cleanupAndRelease:(id)sender
{
	if(didCleanup)
		return;
	didCleanup = YES;

	[sWindowControllers removeObject:self];

	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[self setWindow:nil];

	[self wakeClient];
	[self performSelector:@selector(delayedRelease:) withObject:self afterDelay:0];
}

- (void)delayedRelease:(id)anArgument
{
	[self autorelease];
}

- (void)windowWillClose:(NSNotification*)aNotification
{
	[self wakeClient];
//	[self cleanupAndRelease:self];
}


- (void)connectionDidDie:(NSNotification*)aNotification
{
	[window orderOut:self];
	[self cleanupAndRelease:self];

	// post dummy event, since the system has a tendency to stall the next event, after replying to a DO message where the receiver has disappeared, posting this dummy event seems to solve it
	[NSApp postEvent:[NSEvent otherEventWithType:NSApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0.0f windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
}
@end

@interface NSObject (OakTextView)
- (NSPoint)positionForWindowUnderCaret;
@end

@interface LegacyDialogPopupMenuTarget : NSObject
{
	NSInteger selectedIndex;
}
@property NSInteger selectedIndex;
@end

@implementation LegacyDialogPopupMenuTarget
@synthesize selectedIndex;
- (id)init
{
	if((self = [super init]))
		self.selectedIndex = NSNotFound;
	return self;
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem
{
	return [menuItem action] == @selector(takeSelectedItemIndexFrom:);
}

- (void)takeSelectedItemIndexFrom:(id)sender
{
	NSAssert([sender isKindOfClass:[NSMenuItem class]], @"Unexpected sender for menu target");
	self.selectedIndex = [(NSMenuItem*)sender tag];
}
@end

@implementation Dialog
- (id)initWithPlugInController:(id <TMPlugInController>)aController
{
	NSApp = [NSApplication sharedApplication];
	if(self = [super init])
	{
		NSConnection* connection = [NSConnection new];
		[connection setRootObject:self];

		NSString* portName = [NSString stringWithFormat:@"%@.%d", @"com.macromates.dialog_1", getpid()];
		if([connection registerName:portName] == NO)
			NSLog(@"couldn't setup port: %@", portName), NSBeep();
		setenv("DIALOG_1_PORT_NAME", [portName UTF8String], 1);

		if(NSString* path = [[NSBundle bundleForClass:[self class]] pathForResource:@"tm_dialog" ofType:nil]) {
			if (!getenv("DIALOG"))
				setenv("DIALOG", [path UTF8String], 1);
			else
				setenv("DIALOG_1", [path UTF8String], 1);
		}
	}
	return self;
}

- (int)textMateDialogServerProtocolVersion
{
	return TextMateDialogServerProtocolVersion;
}

// filePath: find the window with this path, and create a sheet on it. If we can't find one, may go app-modal.
- (id)showAlertForPath:(NSString*)filePath withParameters:(NSDictionary *)parameters modal:(BOOL)modal
{
	NSAlertStyle		alertStyle = NSInformationalAlertStyle;
	NSAlert*			alert;
	NSDictionary*		resultDict = nil;
	NSArray*			buttonTitles = [parameters objectForKey:@"buttonTitles"];
	NSString*			alertStyleString = [parameters objectForKey:@"alertStyle"];
		
	alert = [[[NSAlert alloc] init] autorelease];
	
	if([alertStyleString isEqualToString:@"warning"])
	{
		alertStyle = NSWarningAlertStyle;
	}
	else if([alertStyleString isEqualToString:@"critical"])
	{
		alertStyle = NSCriticalAlertStyle;
	}
	else if([alertStyleString isEqualToString:@"informational"])
	{
		alertStyle = NSInformationalAlertStyle;
	}
	
	[alert setAlertStyle:alertStyle];
	[alert setMessageText:[parameters objectForKey:@"messageTitle"]];
	[alert setInformativeText:[parameters objectForKey:@"informativeText"]];
	
	// Setup buttons
	if(buttonTitles != nil && [buttonTitles count] > 0)
	{
		unsigned int	buttonCount = [buttonTitles count];

		// NSAlert always preallocates the OK button.
		// No -- docs are not entirely correct.
//		[[[alert buttons] objectAtIndex:0] setTitle:[buttonTitles objectAtIndex:0]];

		for(unsigned int index = 0; index < buttonCount; index += 1)
		{
			NSString *	buttonTitle = [buttonTitles objectAtIndex:index];

			[alert addButtonWithTitle:buttonTitle];
		}
	}
	
	// Show the alert
	if(not modal)
	{
#if 1
		// Not supported yet; needs same infrastructure as will be required for nib-based sheets.
		[NSException raise:@"NotSupportedYet" format:@"Sheet alerts not yet supported."];
#else
		// Window-modal (sheet).NSWindowController
		// Find the window corresponding to the given path

		NSArray* windows = [NSApp windows];
		NSWindow* chosenWindow = nil;
		
		for(NSWindow * window in windows)
		{
			OakDocumentController*	documentController = [window controller];
			if([documentController isKindOfClass:[OakDocumentController class]])
			{
				if(filePath == nil)
				{
					// Take first visible document window
					if( [window isVisible] )
					{
						chosenWindow = window;
						break;
					}
				}
				else
				{
					// Find given document window
					// TODO: documentWithContentsOfFile may be a better way to do this
					// FIXME: standardize paths
					if([[documentController->textDocument filename] isEqualToString:filePath])
					{
						chosenWindow = window;
						break;
					}
				}
			}
		}
		
		// Fall back to modal
		if(chosenWindow == nil)
		{
			modal = YES;
		}
#endif
	}
	
	if(modal)
	{
		int alertResult = ([alert runModal] - NSAlertFirstButtonReturn);
		
		resultDict = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:alertResult] forKey:@"buttonClicked"];
	}
	return resultDict;
}

- (id)showNib:(NSString*)aNibPath withParameters:(id)someParameters andInitialValues:(NSDictionary*)initialValues dynamicClasses:(NSDictionary*)dynamicClasses modal:(BOOL)modal center:(BOOL)shouldCenter async:(BOOL)async
{
	for(id key in [dynamicClasses allKeys])
		[TMDChameleon createSubclassNamed:key withValues:[dynamicClasses objectForKey:key]];

	id output;
	
	if(![[NSFileManager defaultManager] fileExistsAtPath:aNibPath])
	{
		NSLog(@"%s nib file not found: %@", sel_getName(_cmd), aNibPath);
		return nil;
	}

	if(initialValues && [initialValues count])
		[[NSUserDefaults standardUserDefaults] registerDefaults:initialValues];

	NSNib* nib = [[[NSNib alloc] initWithContentsOfURL:[NSURL fileURLWithPath:aNibPath]] autorelease];
	if(!nib)
	{
		NSLog(@"%s failed loading nib: %@", sel_getName(_cmd), aNibPath);
		return nil;
	}

	TMDNibWindowController* nibOwner = [[TMDNibWindowController alloc] initWithParameters:someParameters modal:modal center:shouldCenter aysnc:async];
	if(!nibOwner)
		NSLog(@"%s couldn't create nib loader", sel_getName(_cmd));
	[nibOwner instantiateNib:nib];
	
//	if(async || (not modal))
	{
		output = [NSMutableDictionary dictionaryWithObjectsAndKeys:
										[NSNumber numberWithUnsignedInt:[nibOwner token]], @"token",
										[NSNumber numberWithUnsignedInt:0], @"returnCode",
										nil];
	}
	// else
	// {
	// 	output = someParameters;
	// }
	return output;
}

// Async updates of parameters
- (id)updateNib:(id)token withParameters:(id)someParameters
{
	TMDWindowController*	windowController	= [TMDWindowController windowControllerForToken:[token intValue]];
	int			resultCode	= -43;
	
	if((windowController != nil)
	&& [windowController isAsync]
	&& [windowController isKindOfClass:[TMDNibWindowController class]])
	{
		[((TMDNibWindowController*)windowController) updateParameters:someParameters];
		resultCode = 0;
	}
	
	return [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInt:resultCode] forKey:@"returnCode"];
}

// Async close
- (id)closeNib:(id)token
{
	TMDWindowController*	windowController	= [TMDWindowController windowControllerForToken:[token intValue]];
	int			resultCode	= -43;
	
	if((windowController != nil) /*&& [windowController isAsync]*/)
	{
		[windowController connectionDidDie:nil];
		resultCode = 0;
	}
	
	return [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInt:resultCode] forKey:@"returnCode"];
}

// Async get results
- (id)retrieveNibResults:(id)token
{
	TMDWindowController*	windowController	= [TMDWindowController windowControllerForToken:[token intValue]];
	int			resultCode	= -43;
	id			results;
	
	if((windowController != nil) /*&& [windowController isAsync]*/)
	{
		results = [windowController returnResult];
		resultCode = 0;
	}
	else
	{
		results = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedInt:resultCode] forKey:@"returnCode"];
	}
	
	return results;
}

// Async list
- (id)listNibTokens
{
	NSMutableDictionary*	dict		= [NSMutableDictionary dictionary];
	NSArray*				outNibArray	= [TMDWindowController nibDescriptions];
	int						resultCode	= 0;
		
	[dict setObject:outNibArray forKey:@"nibs"];
	[dict setObject:[NSNumber numberWithUnsignedInt:resultCode] forKey:@"returnCode"];
	return dict;
}


- (id)showMenuWithOptions:(NSDictionary*)someOptions
{
	NSMenu* menu = [[[NSMenu alloc] init] autorelease];
	[menu setFont:[NSFont menuFontOfSize:([[NSUserDefaults standardUserDefaults] integerForKey:@"OakBundleManagerDisambiguateMenuFontSize"] ?: [NSFont smallSystemFontSize])]];
	LegacyDialogPopupMenuTarget* menuTarget = [[[LegacyDialogPopupMenuTarget alloc] init] autorelease];

	int item_id = 0;
	char key = '0';
	NSArray* menuItems = [[[someOptions objectForKey:@"menuItems"] retain] autorelease];
	for(NSDictionary* menuItem in menuItems)
	{
		if([[menuItem objectForKey:@"separator"] intValue])
		{
			[menu addItem:[NSMenuItem separatorItem]];
		}
		else
		{
			NSMenuItem* theItem = [menu addItemWithTitle:[menuItem objectForKey:@"title"] action:@selector(takeSelectedItemIndexFrom:) keyEquivalent:key++ < '9' ? [NSString stringWithFormat:@"%c", key] : @""];
			[theItem setKeyEquivalentModifierMask:0];
			[theItem setTarget:menuTarget];
			[theItem setTag:item_id];
		}
		++item_id;
	}

	NSPoint pos = [NSEvent mouseLocation];
	if(id textView = [NSApp targetForAction:@selector(positionForWindowUnderCaret)])
		pos = [textView positionForWindowUnderCaret];

	NSMutableDictionary* selectedItem = [NSMutableDictionary dictionary];

	if([menu popUpMenuPositioningItem:nil atLocation:pos inView:nil] && menuTarget.selectedIndex != NSNotFound)
	{
		[selectedItem setObject:[NSNumber numberWithInteger:menuTarget.selectedIndex] forKey:@"selectedIndex"];
		[selectedItem setObject:[menuItems objectAtIndex:menuTarget.selectedIndex] forKey:@"selectedMenuItem"];
	}

	return selectedItem;
}
@end
