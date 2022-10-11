// ==============================================================================
//
// File:		ColorLibrary.h
//
// Purpose:		A repository of methods, functions, and data types used to
// support LDraw colors.
//
// Modified:	2/26/05 Allen Smith. Creation date (LDrawColor.m)
// 3/16/08 Allen Smith. Moved to ColorLibrary as part of
// ldconfig.ldr support.
//
// Copyright 2005. All rights reserved.
// ==============================================================================
#import <Foundation/Foundation.h>
#import OPEN_GL_HEADER

#import "LDrawColor.h"


////////////////////////////////////////////////////////////////////////////////
//
// Protocol:	LDrawColorable
//
// Notes:		This protocol is adopted by classes that accept colors, such as
// LDrawPart and LDrawQuadrilateral.
//
////////////////////////////////////////////////////////////////////////////////
@protocol LDrawColorable

- (LDrawColor *)LDrawColor;
- (void)setLDrawColor:(LDrawColor *)newColor;

@end

////////////////////////////////////////////////////////////////////////////////
//
// Class:		ColorLibrary
//
////////////////////////////////////////////////////////////////////////////////
@interface ColorLibrary : NSObject
{
  // keys are LDrawColorT codes; objects are LDrawColors
  NSMutableDictionary *colors;
  // colors we might be asked to display, but should NOT be in the color picker
  NSMutableDictionary *privateColors;
  // colours in "Favorites"
  NSMutableArray *favorites;
}

// Initialization
+ (ColorLibrary *)sharedColorLibrary;

// Accessors
- (NSArray *)colors;
- (NSArray *)favoriteColors;
- (LDrawColor *)colorForCode:(LDrawColorT)colorCode;
- (void)getComplimentRGBA:(GLfloat *)complimentRGBA forCode:(LDrawColorT)colorCode;
- (void)setFavorites:(NSArray *)favoritesIn;
- (void)addColorToFavorites:(LDrawColorT)color;
- (void)removeColorFromFavorites:(LDrawColorT)color;
- (void)saveFavoritesToUserDefaults;

// Registering Colors
- (void)addColor:(LDrawColor *)newColor;
- (void)addPrivateColor:(LDrawColor *)newColor;

// Utilities

void complimentColor(const GLfloat *originalColor, GLfloat *complimentColor);

@end
