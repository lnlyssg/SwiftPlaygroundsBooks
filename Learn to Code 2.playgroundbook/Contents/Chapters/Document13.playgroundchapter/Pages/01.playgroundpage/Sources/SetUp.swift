// 
//  SetUp.swift
//
//  Copyright (c) 2016 Apple Inc. All Rights Reserved.
//
import Foundation

// MARK: Globals
public let world = GridWorld(columns: 5, rows: 3)


public func playgroundPrologue() {
    Display.coordinateMarkers = true
    world.successCriteria = .pageSpecific(world.coveredInGemsAndSwitches)
   
    placeWater()
    
    // Must be called in `playgroundPrologue()` to update with the current page contents.
    registerAssessment(world, assessment: assessmentPoint)
    
    //// ----
    // Any items added or removed after this call will be animated.
    finalizeWorldBuilding(for: world)
    //// ----
}

public func presentWorld() {
    setUpLiveViewWith(world)
}

// MARK: Epilogue
    
public func playgroundEpilogue() {
    sendCommands(for: world)
}

func placeWater() {
    let rows1and2 = world.coordinates(inRows: [0,2])
    world.removeItems(at: rows1and2)
    world.placeWater(at: rows1and2)
}
