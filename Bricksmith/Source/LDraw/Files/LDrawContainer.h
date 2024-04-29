// ==============================================================================
//
// File:		LDrawContainer.m
//
// Purpose:		Abstract subclass for LDrawDirectives which represent a
// collection of related directives.
//
// Created by Allen Smith on 3/31/05.
// Copyright (c) 2005. All rights reserved.
// ==============================================================================
#import <Foundation/Foundation.h>

#import "LDrawDirective.h"
#import "MatrixMath.h"

@class PartReport;

////////////////////////////////////////////////////////////////////////////////
//
// Class:		LDrawContainer
//
////////////////////////////////////////////////////////////////////////////////
@interface LDrawContainer : LDrawDirective <NSCoding, NSCopying, LDrawObserver>
{
    @protected BOOL postsNotifications;

    @private NSMutableArray *containedObjects;
}

// Accessors
- (NSArray *)allEnclosedElements;
- (Box3)projectedBoundingBoxWithModelView:(Matrix4)modelView projection:(Matrix4)projection view:(Box2)
    viewport;
- (NSInteger)indexOfDirective:(LDrawDirective *)directive;
- (NSMutableArray *)subdirectives;

- (void)setPostsNotifications:(BOOL)flag;
- (void)setSubdirectiveSelected:(BOOL)flag;

// Actions
- (void)addDirective:(LDrawDirective *)directive;
- (void)collectPartReport:(PartReport *)report;
- (void)applyToAllParts:(LDrawPartVisitor)visitor;
- (void)insertDirective:(LDrawDirective *)directive atIndex:(NSInteger)index;
- (void)removeDirective:(LDrawDirective *)doomedDirective;
- (void)removeDirectiveAtIndex:(NSInteger)index;

- (BOOL)acceptsDroppedDirective:(LDrawDirective *)directive;

@end
