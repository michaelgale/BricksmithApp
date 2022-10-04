// ==============================================================================
//
// File:		MLCadIni.h
//
// Purpose:		Parses the contents of LDraw/MLCad.ini, the file which defines
// settings for the minifigure generator.
//
// Created by Allen Smith on 7/2/06.
// Copyright 2006. All rights reserved.
// ==============================================================================
#import <Cocoa/Cocoa.h>


@interface MLCadIni: NSObject
{
  NSArray *lsynthVisibleTypes;

  // Minifigure Generator
  NSMutableArray *minifigureHats;
  NSMutableArray *minifigureHeads;
  NSMutableArray *minifigureNecks;
  NSMutableArray *minifigureTorsos;
  NSMutableArray *minifigureHips;
  NSMutableArray *minifigureArmsLeft;
  NSMutableArray *minifigureArmsRight;
  NSMutableArray *minifigureHandsLeft;
  NSMutableArray *minifigureHandsLeftAccessories;
  NSMutableArray *minifigureHandsRight;
  NSMutableArray *minifigureHandsRightAccessories;
  NSMutableArray *minifigureLegsLeft;
  NSMutableArray *minifigureLegsLeftAcessories;
  NSMutableArray *minifigureLegsRight;
  NSMutableArray *minifigureLegsRightAccessories;
}

// Initialization
+ (MLCadIni *)iniFile;

// Accessors
-(NSArray *)lsynthVisibleTypes;
-(NSArray *)minifigureHats;
-(NSArray *)minifigureHeads;
-(NSArray *)minifigureNecks;
-(NSArray *)minifigureTorsos;
-(NSArray *)minifigureHips;
-(NSArray *)minifigureArmsLeft;
-(NSArray *)minifigureArmsRight;
-(NSArray *)minifigureHandsLeft;
-(NSArray *)minifigureHandsLeftAccessories;
-(NSArray *)minifigureHandsRight;
-(NSArray *)minifigureHandsRightAccessories;
-(NSArray *)minifigureLegsLeft;
-(NSArray *)minifigureLegsLeftAcessories;
-(NSArray *)minifigureLegsRight;
-(NSArray *)minifigureLegsRightAccessories;

-(float)armAngleForTorsoName: (NSString *)torsoName;

// Parsing
-(void)parseFromPath: (NSString *)path;

@end
