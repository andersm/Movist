//
//  Movist
//
//  Copyright 2006 ~ 2008 Yong-Hoe Kim. All rights reserved.
//      Yong-Hoe Kim  <cocoable@gmail.com>
//
//  This file is part of Movist.
//
//  Movist is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 3 of the License, or
//  (at your option) any later version.
//
//  Movist is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "Movist.h"

@interface PlaylistItem : NSObject <NSCopying, NSCoding>
{
    NSURL* _movieURL;
    NSMutableArray* _subtitleURLs;
}

- (id)initWithMovieURL:(NSURL*)movieURL;

#pragma mark -
- (NSURL*)movieURL;
- (NSArray*)subtitleURLs;
- (void)setMovieURL:(NSURL*)movieURL;
- (void)setSubtitleURLs:(NSArray*)subtitleURLs;
- (void)addSubtitleURL:(NSURL*)subtitleURL;
- (void)addSubtitleURLs:(NSArray*)subtitleURLs;
- (void)removeSubtitleURL:(NSURL*)subtitleURL;

#pragma mark -
- (BOOL)isEqualToMovieURL:(NSURL*)movieURL;

@end

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

enum {
    REPEAT_OFF,
    REPEAT_ALL,
    REPEAT_ONE,
    MAX_REPEAT_MODE,
};

enum {
    OPTION_ONLY,
    OPTION_SERIES,
    OPTION_ALL,
};

@interface Playlist : NSObject <NSCoding>
{
    NSMutableArray* _array;     // array of PlaylistItem
    PlaylistItem* _currentItem;

    NSInteger _repeatMode;      // REPEAT_*
}

#pragma mark -
#pragma mark add/remove
- (NSUInteger)count;
- (PlaylistItem*)itemAtIndex:(int)index;
- (void)addFile:(NSString*)filename option:(int)option;
- (void)addFiles:(NSArray*)filenames;
- (void)addURL:(NSURL*)movieURL;
- (NSUInteger)insertFile:(NSString*)filename atIndex:(NSUInteger)index option:(int)option;
- (void)insertFiles:(NSArray*)filenames atIndex:(NSUInteger)index;
- (void)insertURLs:(NSArray*)fileURLs atIndex:(NSUInteger)index;
- (void)insertURL:(NSURL*)movieURL atIndex:(NSUInteger)index;
- (NSUInteger)moveItemsAtIndexes:(NSIndexSet*)indexes
                           toIndex:(NSUInteger)index;
- (void)removeItemAtIndex:(NSUInteger)index;
- (void)removeItemsAtIndexes:(NSIndexSet*)indexes;
- (void)removeAllItems;

#pragma mark -
#pragma mark play
- (PlaylistItem*)currentItem;
- (NSEnumerator*)itemEnumerator;
- (NSUInteger)indexOfItem:(PlaylistItem*)item;
- (void)setCurrentItemAtIndex:(NSInteger)index;
- (void)setPrevItem;
- (void)setNextItem;

#pragma mark -
#pragma mark repeat-mode
- (NSInteger)repeatMode;
- (void)setRepeatMode:(NSInteger)mode;

@end
