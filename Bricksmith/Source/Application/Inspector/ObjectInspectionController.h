// ==============================================================================
//
// File:		ObjectInspectionController.h
//
// Purpose:		Base class for all LDraw inspectors.
//
// Created by Allen Smith on 2/25/05.
// Copyright 2005. All rights reserved.
// ==============================================================================
#import <Cocoa/Cocoa.h>

#import "MatrixMath.h"

////////////////////////////////////////////////////////////////////////////////
//
// ObjectInspectionController
//
////////////////////////////////////////////////////////////////////////////////
@interface ObjectInspectionController : NSObject
{
// IBOutlet NSWindow *window;   // we will vacuum out the content view from this.

    @private
    // The object this inspector edits.
    id editingObject;
}

// Accessors
- (id)object; // returns the object being edited
- (void)setObject:(id)newObject;
- (NSWindow *)window;

// Actions
- (void)commitChanges:(id)sender;
- (IBAction)finishedEditing:(id)sender;
- (IBAction)revert:(id)sender;

// Utilities
- (Point3)coordinateValueFromFields:(NSArray <NSTextField *> *)fields;
- (void)setCoordinateValue:(Point3)newPoint onFields:(NSArray <NSTextField *> *)fields;

@property (nonatomic, strong) IBOutlet NSWindow *window;

@end
