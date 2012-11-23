#import "XVimSourceView+Vim.h"
#import "XVimSourceView+Xcode.h"
#import "DVTSourceTextViewHook.h"
#import "NSString+VimHelper.h"
#import "Logger.h"

/*
 * XVimSourceView represent a text view used in XVim.
 * This is a layer above the actuall text view used in Xcode(DVTSourceTextView)
 * XVimSourceView keeps consistensy between VIM state and DVTSourceTextView.
 * All the evaluators(event handlers) send a request to XVimSourceView via XVimWindow
 * and complete its event.
 * So evaluators should NOT directly operate on DVTSourceTextView.
 */

#define LOG_STATE() TRACE_LOG(@"_view.range loc:%d len:%d | mode %d | ip %d | begin %d | areaS %d | areaE %d", \
                            [_view selectedRange].location, \
                            [_view selectedRange].length,  \
                            _selectionMode,            \
                            _insertionPoint,           \
                            _selectionBegin,           \
                            _selectionAreaStart,       \
                            _selectionAreaEnd)


@interface XVimSourceView() {
	__weak NSTextView *_view;
}
@property (strong) NSMutableString* lastYankedText;
@property TEXT_TYPE lastYankedType;

- (void)_setSelectedRange:(NSRange)range;
- (void)_moveCursor:(NSUInteger)pos preserveColumn:(BOOL)preserve;
- (NSUInteger)_getPositionFrom:(NSUInteger)current Motion:(XVimMotion*)motion;
- (void)_syncStateFromView; // update our instance variables with _view's properties
- (void)_syncState; // update _view's properties with our variables
- (NSArray*)_selectedRanges;
@end

@implementation XVimSourceView
@synthesize insertionPoint = _insertionPoint;
@synthesize selectionBegin = _selectionBegin;
@synthesize selectionAreaStart = _selectionAreaStart;
@synthesize selectionAreaEnd = _selectionAreaEnd;
@synthesize selectionMode = _selectionMode;
@synthesize preservedColumn = _preservedColumn;
@synthesize cursorMode = _cursorMode;
@synthesize lastYankedText = _lastYankedText;
@synthesize lastYankedType = _lastYankedType;
@synthesize delegate = _delegate;

- (id)initWithView:(NSTextView*)view {
	if (self = [super init]) {
		_view = (NSTextView*)view;
        _insertionPoint = [_view selectedRange].location + [_view selectedRange].length;
        _selectionMode = MODE_VISUAL_NONE;
        _selectionBegin = _insertionPoint;
        _selectionAreaStart = _insertionPoint;
        _selectionAreaEnd = _insertionPoint;
        _cursorMode = CURSOR_MODE_COMMAND;
        _lastYankedText = [[NSMutableString alloc] init];
        _lastYankedType = TEXT_TYPE_CHARACTERS;
        self.delegate = nil;
	}
	return self;
}

- (void)dealloc{
    [super dealloc];
    [_lastYankedText release];
    self.delegate = nil;
}

////////////////
// Properties //
////////////////
- (NSTextView*)view {
	return _view;
}
    
- (NSString *)string {
	return [_view string];
}

- (NSArray*)selectedRanges{
    return [_view selectedRanges];
}

- (NSUInteger)insertionColumn{
    return [(XVimSourceView*)_view columnNumber:_insertionPoint];
}

- (NSUInteger)insertionLine{
    return [(XVimSourceView*)_view lineNumber:_insertionPoint];
}

- (NSArray*)_selectedRanges{
    NSMutableArray* rangeArray = [[[NSMutableArray alloc] init] autorelease];
    if( _selectionMode == MODE_VISUAL_NONE){
        [rangeArray addObject:[NSValue valueWithRange:NSMakeRange(_insertionPoint, 0)]];
    }else if( _selectionMode == MODE_CHARACTER){
        [rangeArray addObject:[NSValue valueWithRange:NSMakeRange(_insertionPoint, _selectionAreaEnd - _selectionAreaStart+1)]];
    }else if( _selectionMode == MODE_LINE){
        [rangeArray addObject:[NSValue valueWithRange:NSMakeRange(_selectionAreaStart, _selectionAreaEnd - _selectionAreaStart+1)]];
    }else if( _selectionMode == MODE_BLOCK){
        // Define the block as a rect by line and column number
        NSUInteger top    = MIN( [self lineNumber:_insertionPoint], [self lineNumber:_selectionBegin] );
        NSUInteger bottom = MAX( [self lineNumber:_insertionPoint], [self lineNumber:_selectionBegin] );
        NSUInteger left   = MIN( [self columnNumber:_insertionPoint], [self columnNumber:_selectionBegin] );
        NSUInteger right  = MAX( [self columnNumber:_insertionPoint], [self columnNumber:_selectionBegin] );
        for( NSUInteger i = 0; i < bottom-top+1 ; i++ ){
            //NSUInteger maxColumn = [self maxColumnAtLineNumber:top+i];
            NSUInteger start = [self positionAtLineNumber:top+i column:left];
            NSUInteger end = [self positionAtLineNumber:top+i column:right];
            [rangeArray addObject:[NSValue valueWithRange:NSMakeRange(start, [self isNewLine:end] ? end-start : end-start+1)]];;
        }
    }
    return rangeArray;
}

//////////////////
// Operations   //
//////////////////

////////// Top level operation interface/////////

- (void)escapeFromInsert{
    _cursorMode = CURSOR_MODE_COMMAND;
    [self _syncState];
    _preservedColumn = [self columnNumber:_insertionPoint];
}

- (void)moveCursor:(NSUInteger)pos{
    [self _moveCursor:pos preserveColumn:NO];
}

- (void)move:(XVimMotion*)motion{
    METHOD_TRACE_LOG();
    switch( motion.motion ){
        case MOTION_LINE_BACKWARD:
        case MOTION_LINE_FORWARD:
            // TODO: Preserve column option can be included in motion object
            [self _moveCursor:[self _getPositionFrom:_insertionPoint Motion:motion] preserveColumn:YES];
            break;
        default:
            [self _moveCursor:[self _getPositionFrom:_insertionPoint Motion:motion] preserveColumn:NO];
            break;
    }
}

- (void)_yankSelection:(MOTION_TYPE)type{
    if( _selectionMode == MODE_VISUAL_NONE ){
        if( type == CHARACTERWISE_EXCLUSIVE || type == CHARACTERWISE_INCLUSIVE ){
            _lastYankedType = TEXT_TYPE_CHARACTERS;
        }else if( type == LINEWISE ){
            _lastYankedType = TEXT_TYPE_LINES;
        }
    }else if( _selectionMode == MODE_CHARACTER){
        _lastYankedType = TEXT_TYPE_CHARACTERS;
    }else if( _selectionMode == MODE_LINE ){
        _lastYankedType = TEXT_TYPE_LINES;
    }else if( _selectionMode == MODE_BLOCK ){
        _lastYankedType = TEXT_TYPE_BLOCK;
    }
    TRACE_LOG(@"YANKED TYPE:%d", _lastYankedType);
    
    NSArray* ranges = [_view selectedRanges];
    if( _lastYankedType == TEXT_TYPE_BLOCK ){
        ranges = [self _selectedRanges];
    }
    NSMutableArray* tmp = [[[NSMutableArray alloc] init] autorelease];
    for( NSValue* range in ranges ){
        if( range.rangeValue.length == 0 ){
            // Nothing to yank
            [tmp addObject:@""];
        }else{
            NSString* str = [[_view string] substringWithRange:range.rangeValue];
            [tmp addObject:str];
        }
    }
    
    [_lastYankedText setString:[tmp componentsJoinedByString:@"\n"]];
    TRACE_LOG(@"YANKED STRING : %@", _lastYankedText);
}

- (void)delete:(XVimMotion*)motion{
    NSAssert( !(_selectionMode == MODE_VISUAL_NONE && motion == nil), @"motion must be specified if current selection mode is not visual");
    if( _insertionPoint == 0 && [[self string] length] == 0 ){
        return ;
    }
    
    if( _selectionMode == MODE_VISUAL_NONE ){
        NSRange r;
        NSUInteger to = [self _getPositionFrom:_insertionPoint Motion:motion];
        // We have to treat some special cases
        // When a cursor get end of line with "l" motion, make the motion type to inclusive.
        // This make you to delete the last character. (if its exclusive last character never deleted with "dl")
        if( motion.motion == MOTION_FORWARD && motion.info->reachedEndOfLine){
            motion.type = CHARACTERWISE_INCLUSIVE;
        }
        if( motion.motion == MOTION_WORD_FORWARD ){
            if (motion.info->isFirstWordInALine && motion.info->lastEndOfLine != NSNotFound) {
                to = motion.info->lastEndOfLine;
                motion.type = CHARACTERWISE_INCLUSIVE;
            } else if( motion.info->lastEndOfWord != NSNotFound){
                to = motion.info->lastEndOfWord;
                motion.type = CHARACTERWISE_INCLUSIVE;
            }
        }
        r = [self getOperationRangeFrom:_selectionBegin To:to Type:motion.type];
        BOOL eof = [self isEOF:to];
        BOOL blank = [self isBlankLine:to];
        if( motion.type == LINEWISE && blank && eof){
            if( r.location != 0 ){
                r.location--;
                r.length++;
            }
        }
        [self _setSelectedRange:r];
    }
    
    [self _yankSelection:motion.type];
    [_view delete:self];
    if( _delegate != nil ){
        [_delegate textDeleted:_lastYankedText  withType:_lastYankedType inView:self];
    }
    
    _insertionPoint = _selectionAreaStart;
    [self _syncStateFromView];
    [self changeSelectionMode:MODE_VISUAL_NONE];
}

- (void)yank:(XVimMotion*)motion{
    NSAssert( !(_selectionMode == MODE_VISUAL_NONE && motion == nil), @"motion must be specified if current selection mode is not visual");
    if( _selectionMode == MODE_VISUAL_NONE ){
        NSRange r;
        NSUInteger to = [self _getPositionFrom:_insertionPoint Motion:motion];
        r = [self getOperationRangeFrom:_selectionBegin To:to Type:motion.type];
        BOOL eof = [self isEOF:to];
        BOOL blank = [self isBlankLine:to];
        if( motion.type == LINEWISE && blank && eof){
            if( r.location != 0 ){
                r.location--;
                r.length++;
            }
        }
        [self _setSelectedRange:r];
    }
    
    [self _yankSelection:motion.type];
    if( _delegate != nil ){
        [_delegate textYanked:_lastYankedText  withType:_lastYankedType inView:self];
    }
    
    [self _syncStateFromView];
    [self changeSelectionMode:MODE_VISUAL_NONE];
}

- (void)put:(NSString*)text withType:(TEXT_TYPE)type afterCursor:(bool)after count:(NSUInteger)count{
    // if the paste text has a eol at the end (line oriented), then we are supposed to move to
    // the line boundary and then paste the data in.
    // TODO: This does not work when the text is copied from line which includes EOF since it does not have newline.
    //       If we want to treat the behaviour correctly we should prepare registers to copy and create an attribute to keep 'linewise'
    
    // TODO: dw of a word at the end of a line does not subsequently 'p' back correctly but that's
    // because dw is not working quite right it seems
    
    if( _selectionMode != MODE_VISUAL_NONE ){
        [self delete:nil];
    }
    
    NSUInteger insertionPointAfterPut = _insertionPoint;
    if( type == TEXT_TYPE_CHARACTERS ){
        //Forward insertion point +1 if after flag if on
        if (![self isNewLine:_insertionPoint] && after) {
            _insertionPoint++;
        }
        [self moveCursor:_insertionPoint];
        for(NSUInteger i = 0; i < count ; i++ ){
            [_view insertText:text];
        }
    }else if( type == TEXT_TYPE_LINES ){
        if( after ){
            NSUInteger newline = [self nextNewLine:_insertionPoint];
            if( NSNotFound == newline ){
                // _insertionPoint is on the last line and the line does not have newline end of it.
                // Add newline before paste the string
                [self insertNewlineBelow];
            }else{
                NSUInteger pos = [self nextLine:_insertionPoint column:0 count:1 option:MOTION_OPTION_NONE];
                [self moveCursor:pos];
            }
        }else{
            NSUInteger pos = [self firstNonBlankInALine:_insertionPoint];
            [self moveCursor:pos];
        }
        insertionPointAfterPut = _insertionPoint;
        for(NSUInteger i = 0; i < count ; i++ ){
            [_view insertText:text];
        }
    }else if( type == TEXT_TYPE_BLOCK ){
        //Forward insertion point +1 if after flag if on
        if (![self isNewLine:_insertionPoint] && after) {
            _insertionPoint++;
        }
        insertionPointAfterPut = _insertionPoint;
        
        NSUInteger column = [self columnNumber:_insertionPoint];
        NSUInteger startLine = [self lineNumber:_insertionPoint];
        NSArray* lines = [text componentsSeparatedByString:@"\n"];
        for( NSUInteger i = 0 ; i < lines.count; i++){
            NSString* line = [lines objectAtIndex:i];
            NSUInteger targetLine = startLine + i;
            NSUInteger head = [self positionAtLineNumber:targetLine];
            if( NSNotFound == head ){
                NSAssert( [self lineNumber:_insertionPoint] == [self numberOfLines], @"_insertionPoint must be on the last line at this point");
                [self insertNewlineBelow];
                head = [self positionAtLineNumber:targetLine];
            }
            NSAssert( NSNotFound != head , @"Head of the target line must be found at this point");
            
            // Find next insertion point (in the next line)
            NSUInteger max = [self maxColumnAtLineNumber:[self lineNumber:head]];
            NSAssert( max != NSNotFound , @"Should not be NSNotFound");
            if( column > max ){
                // If the line does not have enough column pad it with spaces
                NSUInteger spaces = column - max;
                NSUInteger end = [self tailOfLine:head];
                [self _setSelectedRange:NSMakeRange(end,0)];
                for( NSUInteger i = 0 ; i < spaces; i++){
                    [self insertText:@" "];
                }
            }
            [self _setSelectedRange:NSMakeRange([self positionAtLineNumber:targetLine column:column],0)];
            for(NSUInteger i = 0; i < count ; i++ ){
                [_view insertText:line];
            }
        }
        
    }
    
    _insertionPoint = insertionPointAfterPut;
    [self _syncState];
    [self changeSelectionMode:MODE_VISUAL_NONE];
}

- (void)swapCase:(XVimMotion*)motion{
    if( _insertionPoint == 0 && [[self string] length] == 0 ){
        return ;
    }
    
    if( _selectionMode == MODE_VISUAL_NONE ){
        if( motion.motion == MOTION_NONE ){
            XVimMotion* m = XVIM_MAKE_MOTION(MOTION_FORWARD,CHARACTERWISE_EXCLUSIVE,LEFT_RIGHT_NOWRAP,motion.count);
            NSUInteger end = [self _getPositionFrom:_insertionPoint Motion:m];
            if( m.info->reachedEndOfLine ){
                [self toggleCaseForRange:[self getOperationRangeFrom:_insertionPoint To:end Type:CHARACTERWISE_INCLUSIVE]];
            }else{
                [self toggleCaseForRange:[self getOperationRangeFrom:_insertionPoint To:end Type:CHARACTERWISE_EXCLUSIVE]];
            }
            _insertionPoint = end;
        }else{
            NSRange r;
            NSUInteger to = [self _getPositionFrom:_insertionPoint Motion:motion];
            r = [self getOperationRangeFrom:_insertionPoint To:to Type:motion.type];
            [self _setSelectedRange:r];
        }
    }else{
        NSArray* ranges = [self _selectedRanges];
        for( NSValue* val in ranges){
            [self toggleCaseForRange:[val rangeValue]];
        }
        _insertionPoint = _selectionAreaStart;
    }

    [self _syncState];
    [self changeSelectionMode:MODE_VISUAL_NONE];
    
}

- (void)makeLowerCase:(XVimMotion*)motion{
    
}

- (void)makeUpperCase:(XVimMotion*)motion{
    
}

- (void)filter:(XVimMotion*)motion{
    
}

- (void)shiftRight:(XVimMotion*)motion{
    
}

- (void)shiftLeft:(XVimMotion*)motion{
    
}

- (void)insertNewlineBelow{
    NSUInteger l = _insertionPoint;
    // TODO: Use _insertionPoint to move cursor
    NSUInteger tail = [self tailOfLine:l];
    [[self view] setSelectedRange:NSMakeRange(tail,0)];
    [[self view] insertNewline:self];
    [self _syncStateFromView];
}

- (void)insertNewlineAbove{
    NSUInteger l = _insertionPoint;
    NSUInteger head = [self headOfLine:l];
    if( NSNotFound == head ){
        head = l;
    }
    if( 0 != head ){
        // TODO: Use _insertionPoint to move cursor
        [[self view] setSelectedRange:NSMakeRange(head-1,0)];
        [[self view] insertNewline:self];
    }else{
        // TODO: Use _insertionPoint to move cursor
        [[self view] setSelectedRange:NSMakeRange(head,0)];
        [[self view] insertNewline:self];
        [[self view] setSelectedRange:NSMakeRange(0,0)];
    }
    
    [self _syncStateFromView];
}

- (void)append{
    NSAssert(_cursorMode == CURSOR_MODE_COMMAND, @"_cursorMode shoud be CURSOR_MODE_COMMAND");
    _cursorMode = CURSOR_MODE_INSERT;
    if( ![self isEOF:_insertionPoint] && ![self isNewLine:_insertionPoint]){
        _insertionPoint++;
    }
    [self insert];
}

- (void)insert{
    _cursorMode = CURSOR_MODE_INSERT;
    [self _syncState];
}

- (void)appendAtEndOfLine{
    _cursorMode = CURSOR_MODE_INSERT;
    [self changeSelectionMode:MODE_VISUAL_NONE];
    [self _moveCursor:[self tailOfLine:_insertionPoint] preserveColumn:NO];
}

- (void)insertBeforeFirstNonBlank{
    _insertionPoint = [self firstNonBlankInALine:_insertionPoint];
    [self insert];
}

- (void)passThroughKeyDown:(NSEvent*)event{
    [(DVTSourceTextView*)_view keyDown_:event];
    [self _syncStateFromView];
}

////////// Premitive Operations (DO NOT USE THESE CODE!)///////////
- (void)moveBack:(NSUInteger)count option:(MOTION_OPTION)opt{
    NSUInteger nextPos = [self prev:_insertionPoint count:count option:opt];
    [self moveCursor:nextPos];
    _preservedColumn = [self columnNumber:_insertionPoint];
}

- (void)moveFoward:(NSUInteger)count option:(MOTION_OPTION)opt{
    XVimMotionInfo info;
    NSUInteger nextPos = [self next:_insertionPoint count:count option:opt info:&info];
    [self moveCursor:nextPos];
    _preservedColumn = [self columnNumber:_insertionPoint];
}

- (void)moveDown:(NSUInteger)count option:(MOTION_OPTION)opt{
    NSUInteger nextPos = [self nextLine:_insertionPoint column:_preservedColumn count:count option:opt];
    [self moveCursor:nextPos];
}

- (void)moveUp:(NSUInteger)count option:(MOTION_OPTION)opt{
    NSUInteger nextPos = [self prevLine:_insertionPoint column:_preservedColumn count:count option:opt];
    [self moveCursor:nextPos];
}

//- (void)wordsForward:(NSUInteger)index count:(NSUInteger)count option:(MOTION_OPTION)opt info:(XVimMotionInfo*)info;

- (void)moveWordsBackward:(NSUInteger)count option:(MOTION_OPTION)opt{
    NSUInteger nextPos = [self wordsBackward:_insertionPoint count:count option:opt];
    [self moveCursor:nextPos];
}

- (void)moveSentencesForward:(NSUInteger)count option:(MOTION_OPTION)opt{
    NSUInteger nextPos = [self sentencesForward:_insertionPoint count:count option:opt];
    [self moveCursor:nextPos];
}

- (void)moveSentencesBackward:(NSUInteger)count option:(MOTION_OPTION)opt{
    NSUInteger nextPos = [self sentencesBackward:_insertionPoint count:count option:opt];
    [self moveCursor:nextPos];
}

- (void)moveParagraphsForward:(NSUInteger)count option:(MOTION_OPTION)opt{
    NSUInteger nextPos = [self paragraphsForward:_insertionPoint count:count option:opt];
    [self moveCursor:nextPos];
}

- (void)moveParagraphsBackward:(NSUInteger)count option:(MOTION_OPTION)opt{
    NSUInteger nextPos = [self paragraphsBackward:_insertionPoint count:count option:opt];
    [self moveCursor:nextPos];
}


// Scrolls
- (void)scrollPageForward:(NSUInteger)count{
    [self pageForward:_insertionPoint count:count];
}

- (void)scrollPageBackward:(NSUInteger)count{
    [self pageBackward:_insertionPoint count:count];
}

- (void)scrollHalfPageForward:(NSUInteger)count{
    [self halfPageForward:_insertionPoint count:count];
}

- (void)scrollHalfPageBackward:(NSUInteger)count{
    [self halfPageBackward:_insertionPoint count:count];
}

- (void)scrollLineForward:(NSUInteger)count{
    [self lineForward:_insertionPoint count:count];
}

- (void)scrollLineBackward:(NSUInteger)count{
    [self lineBackward:_insertionPoint count:count];
}

- (void)upperCase{
    //[self upperCaseForRange:[self _currentSelection]];
}

- (void)lowerCase{
    //[self lowerCaseForRange:[self _currentSelection]];
}

- (void)toggleCaseForRange:(NSRange)range {
    NSString* text = [self string];
	
	NSMutableString *substring = [[text substringWithRange:range] mutableCopy];
	for (NSUInteger i = 0; i < range.length; ++i) {
		NSRange currentRange = NSMakeRange(i, 1);
		NSString *currentCase = [substring substringWithRange:currentRange];
		NSString *upperCase = [currentCase uppercaseString];
		
		NSRange replaceRange = NSMakeRange(i, 1);
		if ([currentCase isEqualToString:upperCase]){
			[substring replaceCharactersInRange:replaceRange withString:[currentCase lowercaseString]];
		}else{
			[substring replaceCharactersInRange:replaceRange withString:upperCase];
		}	
	}
	
	[self insertText:substring replacementRange:range];
}

- (void)upperCaseForRange:(NSRange)range {
    NSString* s = [self string];
	[self insertText:[[s substringWithRange:range] uppercaseString] replacementRange:range];
}

- (void)lowerCaseForRange:(NSRange)range {
    NSString* s = [self string];
	[self insertText:[[s substringWithRange:range] lowercaseString] replacementRange:range];
}

//////////////////////////////
// Selection (Visual Mode)  //
//////////////////////////////

- (void)startSelection:(VISUAL_MODE)mode{
    //NSAssert(_selectionBegin== NSNotFound, @"beginSelection should be called after endSelection");
    _selectionBegin= _insertionPoint;
    _selectionMode = mode;
    if( [_view selectedRange].length != 0 ){
        _selectionAreaStart = [_view selectedRange].location;
        _selectionBegin = _selectionAreaStart;
        _selectionAreaEnd = [_view selectedRange].length + [_view selectedRange].location;
    }else{
        [self moveCursor:_insertionPoint]; // Update selection;
    }
    TRACE_LOG( @"Selection Started: mode:%d ip:%d begin:%d areaStart:%d areaEnd:%d", _selectionMode, _insertionPoint, _selectionBegin, _selectionAreaStart, _selectionAreaEnd);
}

- (void)endSelection{
    //NSAssert(_selectionBegin!= NSNotFound, @"endSelection should be called after beginSelection");
    _selectionMode = MODE_VISUAL_NONE;
    [self moveCursor:_insertionPoint]; // turn selection off
}

- (void)changeSelectionMode:(VISUAL_MODE)mode{
    if( mode == MODE_VISUAL_NONE){
        [self endSelection];
    }
    _selectionMode = mode;
    [self moveCursor:_insertionPoint];
    return;
}

// Scrolling  //
////////////////
#define XVimAddPoint(a,b) NSMakePoint(a.x+b.x,a.y+b.y)  // Is there such macro in Cocoa?
#define XVimSubPoint(a,b) NSMakePoint(a.x-b.x,a.y-b.y)  // Is there such macro in Cocoa?

- (void)pageUp {
	[_view pageUp:self];
}

- (void)pageDown {
	[_view pageDown:self];
}

- (NSUInteger)lineUp:(NSUInteger)index count:(NSUInteger)count { // C-y
  [_view scrollLineUp:self];
  NSRect visibleRect = [[_view enclosingScrollView] contentView].bounds;
  NSRect currentInsertionRect = [[_view layoutManager] boundingRectForGlyphRange:NSMakeRange(index,0) inTextContainer:[_view textContainer]];
  NSPoint relativeInsertionPoint = XVimSubPoint(currentInsertionRect.origin, visibleRect.origin);
  if (relativeInsertionPoint.y > visibleRect.size.height) {
    [_view moveUp:self];
    NSPoint newPoint = [[_view layoutManager] boundingRectForGlyphRange:[_view selectedRange] inTextContainer:[_view textContainer]].origin;
    index = [[_view layoutManager] glyphIndexForPoint:newPoint inTextContainer:[_view textContainer]];
  }
  return index;
}

- (NSUInteger)lineDown:(NSUInteger)index count:(NSUInteger)count { // C-e
  [_view scrollLineDown:self];
  NSRect visibleRect = [[_view enclosingScrollView] contentView].bounds;
  NSRect currentInsertionRect = [[_view layoutManager] boundingRectForGlyphRange:NSMakeRange(index,0) inTextContainer:[_view textContainer]];
  if (currentInsertionRect.origin.y < visibleRect.origin.y) {
    [_view moveDown:self];
    NSPoint newPoint = NSMakePoint(currentInsertionRect.origin.x, visibleRect.origin.y);
    index = [[_view layoutManager] glyphIndexForPoint:newPoint inTextContainer:[_view textContainer]];
  }
  return index;
}

- (NSUInteger)halfPageScrollHelper:(NSUInteger)index count:(NSInteger)count {
    NSScrollView *scrollView = [_view enclosingScrollView];
    NSTextContainer *container = [_view textContainer];
    
    NSRect visibleRect = [scrollView contentView].bounds;
    CGFloat halfSize = visibleRect.size.height/2.0f;
    
    CGFloat scrollSize = halfSize*count;
    NSPoint scrollPoint = NSMakePoint(visibleRect.origin.x, visibleRect.origin.y + scrollSize ); // This may be beyond the beginning or end of document (intentionally)
    
    // Cursor position relative to left-top origin shold be kept after scroll ( Exception is when it scrolls beyond the beginning or end of document)
    NSRect currentInsertionRect = [[_view layoutManager] boundingRectForGlyphRange:NSMakeRange(index,0) inTextContainer:container];
    NSPoint relativeInsertionPoint = XVimSubPoint(currentInsertionRect.origin, visibleRect.origin);
    
    // Cursor Position after scroll
    NSPoint cursorAfterScroll = XVimAddPoint(scrollPoint,relativeInsertionPoint);
    
    // Nearest character index to the cursor position after scroll
    NSUInteger cursorIndexAfterScroll= [[_view layoutManager] glyphIndexForPoint:cursorAfterScroll inTextContainer:container fractionOfDistanceThroughGlyph:NULL];
    // We do not want to change the insert point relative position from top of visible rect
    // We have to calc the distance between insertion point befor/after scrolling to keep the position.
    NSRect insertionRectAfterScroll = [[_view layoutManager] boundingRectForGlyphRange:NSMakeRange(cursorIndexAfterScroll,0) inTextContainer:container];
    NSPoint relativeInsertionPointAfterScroll = XVimSubPoint(insertionRectAfterScroll.origin, scrollPoint);
    CGFloat heightDiff = relativeInsertionPointAfterScroll.y - relativeInsertionPoint.y;
    scrollPoint.y += heightDiff;
    // Prohibit scroll beyond the bounds of document
    if( scrollPoint.y > [[scrollView documentView] frame].size.height - visibleRect.size.height ){
        scrollPoint.y = [[scrollView documentView] frame].size.height - visibleRect.size.height ;
    } else if (scrollPoint.y < 0.0) {
      scrollPoint.y = 0.0;
    }
  
    [[scrollView contentView] scrollToPoint:scrollPoint];
    [scrollView reflectScrolledClipView:[scrollView contentView]];
	
	return cursorIndexAfterScroll;
}

- (NSUInteger)halfPageDown:(NSUInteger)index count:(NSUInteger)count {
  return [self halfPageScrollHelper:index count:(NSInteger)count];
}

- (NSUInteger)halfPageUp:(NSUInteger)index count:(NSUInteger)count {
  return [self halfPageScrollHelper:index count:-(NSInteger)count];
}

- (NSUInteger)scrollBottom:(NSNumber*)count { // zb / z-
    NSScrollView *scrollView = [_view enclosingScrollView];
    NSTextContainer *container = [_view textContainer];
    NSRect glyphRect = [[_view layoutManager] boundingRectForGlyphRange:[self selectedRange] inTextContainer:container];
    NSPoint bottom = NSMakePoint(0.0f, NSMidY(glyphRect) + NSHeight(glyphRect) / 2.0f);
    bottom.y -= NSHeight([[scrollView contentView] bounds]);
    if( bottom.y < 0.0 ){
        bottom.y = 0.0;
    }
    [[scrollView contentView] scrollToPoint:bottom];
    [scrollView reflectScrolledClipView:[scrollView contentView]];
    return [self selectedRange].location;
}

- (NSUInteger)scrollCenter:(NSNumber*)count { // zz / z.
    NSScrollView *scrollView = [_view enclosingScrollView];
    NSTextContainer *container = [_view textContainer];
    NSRect glyphRect = [[_view layoutManager] boundingRectForGlyphRange:[self selectedRange] inTextContainer:container];
    NSPoint center = NSMakePoint(0.0f, NSMidY(glyphRect) - NSHeight(glyphRect) / 2.0f);
    center.y -= NSHeight([[scrollView contentView] bounds]) / 2.0f;
    if( center.y < 0.0 ){
        center.y = 0.0;
    }
    [[scrollView contentView] scrollToPoint:center];
    [scrollView reflectScrolledClipView:[scrollView contentView]];
    return [self selectedRange].location;
}

- (NSUInteger)scrollTop:(NSNumber*)count { // zt / z<CR>
    NSScrollView *scrollView = [_view enclosingScrollView];
    NSTextContainer *container = [_view textContainer];
    NSRect glyphRect = [[_view layoutManager] boundingRectForGlyphRange:[self selectedRange] inTextContainer:container];
    NSPoint top = NSMakePoint(0.0f, NSMidY(glyphRect) - NSHeight(glyphRect) / 2.0f);
    [[scrollView contentView] scrollToPoint:top];
    [scrollView reflectScrolledClipView:[scrollView contentView]];
    return [self selectedRange].location;
}

- (void)scrollTo:(NSUInteger)location {
	BOOL isBlankLine = 
		(location == [[self string] length] || isNewLine([[self string] characterAtIndex:location])) &&
		(location == 0 || isNewLine([[self string] characterAtIndex:location-1]));

    NSRange characterRange;
    characterRange.location = location;
    characterRange.length = isBlankLine ? 0 : 1;
    
    // Must call ensureLayoutForGlyphRange: to fix a bug where it will not scroll
    // to the appropriate glyph due to non contiguous layout
    NSRange glyphRange = [[_view layoutManager] glyphRangeForCharacterRange:characterRange actualCharacterRange:NULL];
    [[_view layoutManager] ensureLayoutForGlyphRange:NSMakeRange(0, glyphRange.location + glyphRange.length)];
    
    NSTextContainer *container = [_view textContainer];
    NSScrollView *scrollView = [_view enclosingScrollView];
    NSRect glyphRect = [[_view layoutManager] boundingRectForGlyphRange:glyphRange inTextContainer:container];

    CGFloat glyphLeft = NSMidX(glyphRect) - NSWidth(glyphRect) / 2.0f;
    CGFloat glyphRight = NSMidX(glyphRect) + NSWidth(glyphRect) / 2.0f;

    NSRect contentRect = [[scrollView contentView] bounds];
    CGFloat viewLeft = contentRect.origin.x;
    CGFloat viewRight = contentRect.origin.x + NSWidth(contentRect);

    NSPoint scrollPoint = contentRect.origin;
    if (glyphRight > viewRight){
        scrollPoint.x = glyphLeft - NSWidth(contentRect) / 2.0f;
    }else if (glyphLeft < viewLeft){
        scrollPoint.x = glyphRight - NSWidth(contentRect) / 2.0f;
    }

    CGFloat glyphBottom = NSMidY(glyphRect) + NSHeight(glyphRect) / 2.0f;
    CGFloat glyphTop = NSMidY(glyphRect) - NSHeight(glyphRect) / 2.0f;

    CGFloat viewTop = contentRect.origin.y;
    CGFloat viewBottom = contentRect.origin.y + NSHeight(contentRect);

    if (glyphTop < viewTop){
        if (viewTop - glyphTop > NSHeight(contentRect)){
            scrollPoint.y = glyphBottom - NSHeight(contentRect) / 2.0f;
        }else{
            scrollPoint.y = glyphTop;
        }
    }else if (glyphBottom > viewBottom){
        if (glyphBottom - viewBottom > NSHeight(contentRect)) {
            scrollPoint.y = glyphBottom - NSHeight(contentRect) / 2.0f;
        }else{
            scrollPoint.y = glyphBottom - NSHeight(contentRect);
        }
    }

    scrollPoint.x = MAX(0, scrollPoint.x);
    scrollPoint.y = MAX(0, scrollPoint.y);

    [[scrollView  contentView] scrollToPoint:scrollPoint];
    [scrollView reflectScrolledClipView:[scrollView contentView]];
}

- (NSUInteger)cursorBottom:(NSNumber*)count { // L
    NSScrollView *scrollView = [_view enclosingScrollView];
    NSTextContainer *container = [_view textContainer];
    NSRect glyphRect = [[_view layoutManager] boundingRectForGlyphRange:[self selectedRange] inTextContainer:container];
    NSPoint bottom = [[scrollView contentView] bounds].origin;
    bottom.y += [[scrollView contentView] bounds].size.height - NSHeight(glyphRect) / 2.0f;
    NSRange range = { [[scrollView documentView] characterIndexForInsertionAtPoint:bottom], 0 };
    
    [self setSelectedRange:range];
    return [self selectedRange].location;
}

- (NSUInteger)cursorCenter:(NSNumber*)count { // M
    NSScrollView *scrollView = [_view enclosingScrollView];
    NSPoint center = [[scrollView contentView] bounds].origin;
    center.y += [[scrollView contentView] bounds].size.height / 2;
    NSRange range = { [[scrollView documentView] characterIndexForInsertionAtPoint:center], 0 };
    
    [self setSelectedRange:range];
    return [self selectedRange].location;
}

- (NSUInteger)cursorTop:(NSNumber*)count { // H
    NSScrollView *scrollView = [_view enclosingScrollView];
    NSTextContainer *container = [_view textContainer];
    NSRect glyphRect = [[_view layoutManager] boundingRectForGlyphRange:[self selectedRange] inTextContainer:container];
    NSPoint top = [[scrollView contentView] bounds].origin;
    top.y += NSHeight(glyphRect) / 2.0f;
    NSRange range = { [[scrollView documentView] characterIndexForInsertionAtPoint:top], 0 };
    
    [self setSelectedRange:range];
    return [self selectedRange].location;
}

- (NSUInteger)glyphIndexForPoint:(NSPoint)point {
	NSUInteger glyphIndex = [[_view layoutManager] glyphIndexForPoint:point inTextContainer:[_view textContainer]];
	return glyphIndex;
}

- (NSRect)boundingRectForGlyphIndex:(NSUInteger)glyphIndex {
	NSRect glyphRect = [[_view layoutManager] boundingRectForGlyphRange:NSMakeRange(glyphIndex, 1)  inTextContainer:[_view textContainer]];
	return glyphRect;
}

- (void)deleteText {
	[_view delete:self];
}

- (void)cutText {
	[_view cut:self];
}

- (void)copyText {
	[_view copy:self];
}

- (void)moveUp {
	[_view moveUp:self];
}

- (void)moveDown {
	[_view moveDown:self];
}

- (void)moveForward {
    [self move:XVIM_MAKE_MOTION(MOTION_FORWARD, CHARACTERWISE_INCLUSIVE, MOTION_OPTION_NONE, 0)];
}

- (void)moveForwardAndModifySelection {
	[_view moveForwardAndModifySelection:self];
}

- (void)moveBackward {
    [self move:XVIM_MAKE_MOTION(MOTION_BACKWARD, CHARACTERWISE_INCLUSIVE, MOTION_OPTION_NONE, 0)];
}

- (void)moveBackwardAndModifySelection {
	[_view moveBackwardAndModifySelection:self];
}
	 
- (void)moveToBeginningOfLine {
    [self move:XVIM_MAKE_MOTION(MOTION_BEGINNING_OF_LINE, CHARACTERWISE_INCLUSIVE, MOTION_OPTION_NONE, 0)];
}

- (void)moveToEndOfLine {
    [self move:XVIM_MAKE_MOTION(MOTION_END_OF_LINE, CHARACTERWISE_INCLUSIVE, MOTION_OPTION_NONE, 0)];
}

- (void)deleteForward {
	[_view deleteForward:self];
}

- (void)insertText:(NSString*)text {
	[_view insertText:text];
}

- (void)insertText:(NSString*)text replacementRange:(NSRange)range {
	[_view insertText:text replacementRange:range];
}

- (void)insertNewline {
	[_view insertNewline:self];
}

- (void)undo {
	[[_view undoManager] undo];
    [self changeSelectionMode:MODE_VISUAL_NONE];
}

- (void)redo {
	[[_view undoManager] redo];
    [self changeSelectionMode:MODE_VISUAL_NONE];
}

- (NSColor*)insertionPointColor {
	return [_view insertionPointColor];
}

- (void)showFindIndicatorForRange:(NSRange)range {
	[_view showFindIndicatorForRange:range];
}

- (NSRange)selectedRange {
    LOG_STATE();
    return NSMakeRange(_insertionPoint, 0);
}

- (void)setSelectedRange:(NSRange)range {
    LOG_STATE();
    @try{
        _insertionPoint = range.location;
        _selectionAreaStart = _insertionPoint;
        _selectionBegin = _insertionPoint;
        _selectionAreaEnd = _insertionPoint;
        if( 0 != range.length ){
            _selectionAreaStart = _insertionPoint;
            _selectionBegin = _insertionPoint;
            _selectionAreaEnd = range.location + range.length - 1;
        }
        [self _syncState];
    }@catch (NSException *exception) {
        ERROR_LOG(@"main:Caught %@:%@", [exception name], [exception reason]);
    }
    LOG_STATE();
}

//////////////////////
// Internal Methods //
//////////////////////
- (NSUInteger)_getPositionFrom:(NSUInteger)current Motion:(XVimMotion*)motion{
    NSUInteger nextPos = current;
    NSUInteger tmpPos = NSNotFound;
    switch (motion.motion) {
        case MOTION_NONE:
            // Do nothing
            break;
        case MOTION_FORWARD:
            nextPos = [self next:current count:motion.count option:motion.option info:motion.info];
            break;
        case MOTION_BACKWARD:
            nextPos = [self prev:_insertionPoint count:motion.count option:motion.option ];
            break;
        case MOTION_WORD_FORWARD:
            nextPos = [self wordsForward:current count:motion.count option:motion.option info:motion.info];
            break;
        case MOTION_WORD_BACKWARD:
            nextPos = [self wordsBackward:current count:motion.count option:motion.option];
            break;
        case MOTION_END_OF_WORD_FORWARD:
            nextPos = [self endOfWordsForward:current count:motion.count option:motion.option];
            break;
        case MOTION_END_OF_WORD_BACKWARD:
            nextPos = [self endOfWordsBackward:current count:motion.count option:motion.option];
            break;
        case MOTION_LINE_FORWARD:
            nextPos = [self nextLine:current column:_preservedColumn count:motion.count option:motion.option];
            break;
        case MOTION_LINE_BACKWARD:
            nextPos = [self prevLine:current column:_preservedColumn count:motion.count option:motion.option];
            break;
        case MOTION_BEGINNING_OF_LINE:
            nextPos = [self firstOfLine:current];
            if( nextPos == NSNotFound){
                nextPos = current;
            }
            break;
        case MOTION_END_OF_LINE:
            tmpPos = [self nextLine:current column:0 count:motion.count-1 option:MOTION_OPTION_NONE];
            nextPos = [self endOfLine:tmpPos];
            if( nextPos == NSNotFound){
                nextPos = tmpPos;
            }
            break;
        case MOTION_SENTENCE_FORWARD:
            nextPos = [self sentencesForward:current count:motion.count option:motion.option];
            break;
        case MOTION_SENTENCE_BACKWARD:
            nextPos = [self sentencesBackward:current count:motion.count option:motion.option];
            break;
        case MOTION_PARAGRAPH_FORWARD:
            nextPos = [self paragraphsForward:current count:motion.count option:motion.option];
            if( nextPos != NSNotFound){
                nextPos = current;
            }
            break;
        case MOTION_PARAGRAPH_BACKWARD:
            nextPos = [self paragraphsBackward:current count:motion.count option:motion.option];
            if( nextPos != NSNotFound){
                nextPos = current;
            }
            break;
        case MOTION_NEXT_FIRST_NONBLANK:
            nextPos = [self nextLine:current column:0 count:motion.count option:motion.option];
            tmpPos = [self nextNonBlankInALine:nextPos];
            if( NSNotFound != tmpPos ){
                nextPos = tmpPos;
            }
            break;
        case MOTION_PREV_FIRST_NONBLANK:
            nextPos = [self prevLine:current column:0 count:motion.count option:motion.option];
            tmpPos = [self nextNonBlankInALine:nextPos];
            if( NSNotFound != tmpPos ){
                nextPos = tmpPos;
            }
            break;
        case MOTION_FIRST_NONBLANK:
            nextPos = [self headOfLineWithoutSpaces:current];
            if( NSNotFound == nextPos ){
                nextPos = current;
            }
            break;
        case MOTION_LINENUMBER:
            nextPos = [self positionAtLineNumber:motion.line column:0];
            if (nextPos == NSNotFound) {
                nextPos = [self firstOfLine:[self endOfFile]];
            }
            break;
        case MOTION_LASTLINE:
            nextPos = [self firstOfLine:[self endOfFile]];
            break;
        case MOTION_LINE_COLUMN:
            nextPos = [self positionAtLineNumber:motion.line column:motion.column];
            if( NSNotFound == nextPos ){
                nextPos = current;
            }
            break;
        case MOTION_POSITION:
            nextPos = motion.position;
            break;
    }
    TRACE_LOG(@"nextPos: %u", nextPos);
    return nextPos;
}

- (void)_moveCursor:(NSUInteger)pos preserveColumn:(BOOL)preserve{
    // This method only update the internal state(like _insertionPoint)
    // syncState applies the variables to underlying _view at the end of this method.
    
    if( pos > [_view string].length){
        DEBUG_LOG(@"Position specified exceeds the length of the text");
        pos = [_view string].length;
    }
    
    if( _cursorMode == CURSOR_MODE_COMMAND ){
        _insertionPoint = [self convertToValidCursorPositionForNormalMode:pos];
    }else{
        _insertionPoint = pos;
    }
    
    [self _syncState];
    
    if( !preserve ){
        _preservedColumn = [self columnNumber:_insertionPoint];
    }
    
}

- (void)_syncStateFromView{
    // TODO: handle block selection (if selectedRanges have multiple ranges )
    NSRange r = [_view selectedRange];
    if( r.length == 0 ){
        _selectionMode = MODE_VISUAL_NONE;
        _insertionPoint = r.location;
        _selectionBegin = _insertionPoint;
        _selectionAreaStart = _insertionPoint;
        _selectionAreaEnd = _insertionPoint;
    }else{
        _selectionMode = MODE_CHARACTER;
        NSSelectionAffinity affinity = [_view selectionAffinity];
        _selectionBegin = r.location;
        _selectionAreaStart = _selectionBegin;
        _selectionAreaEnd = r.location + r.length -1;
        if( affinity == NSSelectionAffinityDownstream ){
            _insertionPoint = r.location + r.length - 1;
        }else{
            _insertionPoint = r.location;
        }
    }
    
    // Apply it back to _view
    [self _syncState];
}

/**
 * Applies internal state to underlying view (_view).
 * This update _view's property and applies the visual effect on it.
 * All the state need to express Vim is held by this class and
 * we use _view to express it visually.
 **/
- (void)_syncState{
    if (_selectionMode == MODE_VISUAL_NONE) { // its not in selecting mode
        _selectionBegin = _insertionPoint;
        _selectionAreaStart = _insertionPoint;
        _selectionAreaEnd = _insertionPoint;
        [self _setSelectedRange:NSMakeRange(_insertionPoint,0)];
    }
    else if( _selectionMode == MODE_CHARACTER){
        _selectionAreaStart = MIN(_insertionPoint,_selectionBegin);
        _selectionAreaEnd = MAX(_insertionPoint,_selectionBegin);
        [self _setSelectedRange:NSMakeRange(_selectionAreaStart,_selectionAreaEnd-_selectionAreaStart+1)];
    }else if(_selectionMode == MODE_LINE ){
        NSUInteger min = MIN(_insertionPoint,_selectionBegin);
        NSUInteger max = MAX(_insertionPoint,_selectionBegin);
        _selectionAreaStart = [self firstOfLine:min];
        _selectionAreaEnd = [self tailOfLine:max];
        [self _setSelectedRange:NSMakeRange(_selectionAreaStart,_selectionAreaEnd-_selectionAreaStart+1)];
    }else if( _selectionMode == MODE_BLOCK){
        // Find out the rect of the block
        [_view setSelectedRanges:[self _selectedRanges]];
    }
    
    if( _cursorMode == CURSOR_MODE_COMMAND ){
        [self adjustCursorPosition];
    }
    [_view scrollRangeToVisible:NSMakeRange(_insertionPoint,0)];
}

// _setSelectedRange is an internal method
// This is used when you want to call [_view setSelectedRrange];
// The difference is that this checks the bounds(range can not be include EOF) and protect from Assersion
- (void)_setSelectedRange:(NSRange)range{
    LOG_STATE();
    TRACE_LOG( @"Range %d,%d", range.location, range.length);
    if( [self isEOF:range.location] ){
        [_view setSelectedRange:NSMakeRange(range.location,0)];
        return;
    }
    if( 0 == range.length ){
        // No need to check bounds
    }else{
        NSUInteger lastIndex = range.location + range.length - 1;
        if( [self isEOF:lastIndex] ){
            range.length--;
        }else{
            // No need to change the selection area
        }
    }
    [_view setSelectedRange:range];
    LOG_STATE();
}


@end
