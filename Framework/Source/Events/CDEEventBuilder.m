//
//  CDEEventFactory.m
//  Ensembles
//
//  Created by Drew McCormack on 22/09/13.
//  Copyright (c) 2013 Drew McCormack. All rights reserved.
//

#import "CDEEventBuilder.h"
#import "NSManagedObjectModel+CDEAdditions.h"
#import "CDEPersistentStoreEnsemble.h"
#import "CDEEventStore.h"
#import "CDEStoreModificationEvent.h"
#import "CDEDefines.h"
#import "CDEFoundationAdditions.h"
#import "CDEPropertyChangeValue.h"
#import "CDEGlobalIdentifier.h"
#import "CDEObjectChange.h"
#import "CDEEventRevision.h"
#import "CDERevisionSet.h"
#import "CDERevision.h"
#import "CDERevisionManager.h"

@implementation CDEEventBuilder

@synthesize event = event;
@synthesize eventStore = eventStore;
@synthesize eventManagedObjectContext = eventManagedObjectContext;

#pragma mark - Initialization

- (id)initWithEventStore:(CDEEventStore *)newStore eventManagedObjectContext:(NSManagedObjectContext *)newContext
{
    self = [super init];
    if (self) {
        eventStore = newStore;
        eventManagedObjectContext = newContext;
    }
    return self;
}

- (id)initWithEventStore:(CDEEventStore *)newStore
{
    return [self initWithEventStore:newStore eventManagedObjectContext:newStore.managedObjectContext];
}

#pragma mark - Making New Events

- (void)makeNewEventOfType:(CDEStoreModificationEventType)type
{
    [eventManagedObjectContext performBlockAndWait:^{
        CDERevisionNumber lastRevision = eventStore.lastRevision;
        CDERevisionNumber lastMergeRevision = eventStore.lastMergeRevision;
        NSString *persistentStoreId = self.eventStore.persistentStoreIdentifier;
        
        CDERevisionManager *revisionManager = [[CDERevisionManager alloc] initWithEventStore:eventStore];
        revisionManager.managedObjectModelURL = self.ensemble.managedObjectModelURL;
        CDEGlobalCount globalCountBeforeMerge = [revisionManager maximumGlobalCount];

        event = [NSEntityDescription insertNewObjectForEntityForName:@"CDEStoreModificationEvent" inManagedObjectContext:eventManagedObjectContext];
        
        event.type = type;
        event.timestamp = [NSDate timeIntervalSinceReferenceDate];
        event.globalCount = globalCountBeforeMerge+1;
        event.modelVersion = [self.ensemble.managedObjectModel cde_entityHashesPropertyList];
        
        CDEEventRevision *revision = [NSEntityDescription insertNewObjectForEntityForName:@"CDEEventRevision" inManagedObjectContext:eventManagedObjectContext];
        revision.persistentStoreIdentifier = self.eventStore.persistentStoreIdentifier;
        revision.revisionNumber = lastRevision+1;
        revision.storeModificationEvent = event;
        
        // Set the state of other stores
        if (type == CDEStoreModificationEventTypeSave) {
            CDEStoreModificationEvent *lastMergeEvent = [CDEStoreModificationEvent fetchStoreModificationEventForPersistentStoreIdentifier:persistentStoreId revisionNumber:lastMergeRevision inManagedObjectContext:eventManagedObjectContext];
            CDERevisionSet *lastMergeRevisionsSet = lastMergeEvent.revisionSet;
            [lastMergeRevisionsSet removeRevisionForPersistentStoreIdentifier:persistentStoreId];
            if (!lastMergeRevisionsSet) lastMergeRevisionsSet = [[CDERevisionSet alloc] init]; // No previous merge exists
            event.revisionSetOfOtherStoresAtCreation = lastMergeRevisionsSet;
        }
        else if (type == CDEStoreModificationEventTypeMerge) {
            CDERevisionSet *mostRecentSet = [revisionManager revisionSetOfMostRecentEvents];
            [mostRecentSet removeRevisionForPersistentStoreIdentifier:self.eventStore.persistentStoreIdentifier];
            event.revisionSetOfOtherStoresAtCreation = mostRecentSet;
        }
    }];
}

#pragma mark - Modifying Events

- (void)performBlockAndWait:(CDECodeBlock)block
{
    [eventManagedObjectContext performBlockAndWait:block];
}

#pragma mark - Adding Object Changes

- (void)addChangesForInsertedObjects:(NSSet *)insertedObjects objectsAreSaved:(BOOL)saved inManagedObjectContext:(NSManagedObjectContext *)context
{
    if (insertedObjects.count == 0) return;
    
    // Created property value change objects from the inserted objects
    __block NSMutableArray *changeArrays = nil;
    __block NSMutableArray *entityNames = nil;
    __block NSArray *globalIdStrings = nil;

    NSManagedObjectContext *insertedObjectsContext = context;
    
    // Create block to make property change values from the objects
    CDECodeBlock block = ^{
        @autoreleasepool {
            changeArrays = [NSMutableArray arrayWithCapacity:insertedObjects.count];
            entityNames = [NSMutableArray array];
            
            NSArray *orderedInsertedObjects = insertedObjects.allObjects;
            [orderedInsertedObjects cde_enumerateObjectsDrainingEveryIterations:50 usingBlock:^(NSManagedObject *object, NSUInteger index, BOOL *stop) {
                NSArray *propertyChanges = [CDEPropertyChangeValue propertyChangesForObject:object propertyNames:object.entity.propertiesByName.allKeys isPreSave:!saved storeValues:YES];
                if (!propertyChanges) return;
                
                [changeArrays addObject:propertyChanges];
                [entityNames addObject:object.entity.name];
            }];
            
            // Get global id strings on context thread
            globalIdStrings = [[self.ensemble globalIdentifiersForManagedObjects:orderedInsertedObjects] copy];
        }
    };
    
    // Execute the block on the context's thread
    if (insertedObjectsContext.concurrencyType == NSPrivateQueueConcurrencyType)
        [insertedObjectsContext performBlockAndWait:block];
    else
        block();
    
    // Build the event from the property changes on the event store thread
    [eventManagedObjectContext performBlockAndWait:^{
        
        // Retrieve existing global identifiers
        NSArray *existingGlobalIdentifiers = nil;
        if (globalIdStrings) {
            [CDEGlobalIdentifier fetchGlobalIdentifiersForIdentifierStrings:globalIdStrings withEntityNames:entityNames inManagedObjectContext:eventManagedObjectContext];
        }
        
        // Make global ids for all objects first before creating object changes.
        // We need all global ids to exist before trying to store relationships which utilize global ids.
        NSMutableArray *globalIds = [[NSMutableArray alloc] init];
        __block NSUInteger i = 0;
        [changeArrays cde_enumerateObjectsDrainingEveryIterations:50 usingBlock:^(NSArray *propertyChanges, NSUInteger index, BOOL *stop) {
            NSString *entityName = entityNames[i];
            NSString *globalIdString = CDENSNullToNil(globalIdStrings[i]);
            CDEGlobalIdentifier *existingGlobalIdentifier = CDENSNullToNil(existingGlobalIdentifiers[i]);
            i++;
            
            CDEGlobalIdentifier *newGlobalId = existingGlobalIdentifier;
            if (!newGlobalId) {
                newGlobalId = [NSEntityDescription insertNewObjectForEntityForName:@"CDEGlobalIdentifier" inManagedObjectContext:eventManagedObjectContext];
                newGlobalId.nameOfEntity = entityName;
                if (globalIdString) newGlobalId.globalIdentifier = globalIdString;
            }
            
            CDEPropertyChangeValue *propertyChange = propertyChanges.lastObject;
            newGlobalId.storeURI = propertyChange.objectID.URIRepresentation.absoluteString;
            
            [globalIds addObject:newGlobalId];
        }];
        
        // Now that all global ids exist, create object changes
        i = 0;
        [changeArrays cde_enumerateObjectsDrainingEveryIterations:50 usingBlock:^(NSArray *propertyChanges, NSUInteger index, BOOL *stop) {
            CDEGlobalIdentifier *newGlobalId = globalIds[i];
            NSString *entityName = entityNames[i];
            [self addObjectChangeOfType:CDEObjectChangeTypeInsert forGlobalIdentifier:newGlobalId entityName:entityName propertyChanges:propertyChanges];
            i++;
        }];
    }];
}

- (void)addChangesForDeletedObjects:(NSSet *)deletedObjects inManagedObjectContext:(NSManagedObjectContext *)context
{
    if (deletedObjects.count == 0) return;
    
    __block NSArray *orderedObjectIDs = nil;
    NSManagedObjectContext *deletedObjectsContext = context;
    
    CDECodeBlock block = ^{
        NSSet *deletedObjectIds = [deletedObjects valueForKeyPath:@"objectID"];
        orderedObjectIDs = deletedObjectIds.allObjects;
    };
    
    // Execute the block on the context's thread
    if (deletedObjectsContext.concurrencyType == NSPrivateQueueConcurrencyType)
        [deletedObjectsContext performBlockAndWait:block];
    else
        block();
    
    [eventManagedObjectContext performBlockAndWait:^{
        NSArray *globalIds = [CDEGlobalIdentifier fetchGlobalIdentifiersForObjectIDs:orderedObjectIDs inManagedObjectContext:eventManagedObjectContext];
        [globalIds enumerateObjectsUsingBlock:^(CDEGlobalIdentifier *globalId, NSUInteger i, BOOL *stop) {
            NSManagedObjectID *objectID = orderedObjectIDs[i];
            
            if (globalId == (id)[NSNull null]) {
                CDELog(CDELoggingLevelWarning, @"Deleted object with no global identifier. Skipping.");
                return;
            }
            
            CDEObjectChange *change = [NSEntityDescription insertNewObjectForEntityForName:@"CDEObjectChange" inManagedObjectContext:eventManagedObjectContext];
            change.storeModificationEvent = self.event;
            change.type = CDEObjectChangeTypeDelete;
            change.nameOfEntity = objectID.entity.name;
            change.globalIdentifier = globalId;
        }];
    }];
}

- (void)addChangesForSavedUpdatedObjects:(NSSet *)updatedObjects inManagedObjectContext:(NSManagedObjectContext *)context propertyChangeValuesByObjectID:(NSDictionary *)propertyChangeValuesByObjectID
{
    if (updatedObjects.count == 0) return;
    
    // Can't access objects in background, so just pass ids
    __block NSArray *objectIDs = nil;
    NSManagedObjectContext *updatedObjectsContext = context;
    CDECodeBlock block = ^{
        NSArray *objects = [updatedObjects allObjects];
        
        // Update property changes with saved values
        NSMutableArray *newObjectIDs = [[NSMutableArray alloc] initWithCapacity:objects.count];
        for (NSManagedObject *object in objects) {
            NSManagedObjectID *objectID = object.objectID;
            [newObjectIDs addObject:objectID];
            
            NSArray *propertyChanges = [propertyChangeValuesByObjectID objectForKey:objectID];
            for (CDEPropertyChangeValue *propertyChangeValue in propertyChanges) {
                [propertyChangeValue updateWithObject:object isPreSave:NO storeValues:YES];
            }
        }
        objectIDs = newObjectIDs;
    };
    
    if (updatedObjectsContext.concurrencyType != NSConfinementConcurrencyType)
        [updatedObjectsContext performBlockAndWait:block];
    else
        block();
    
    NSPersistentStoreCoordinator *coordinator = updatedObjectsContext.persistentStoreCoordinator;
    [eventManagedObjectContext performBlockAndWait:^{
        NSArray *globalIds = [CDEGlobalIdentifier fetchGlobalIdentifiersForObjectIDs:objectIDs inManagedObjectContext:eventManagedObjectContext];
        [globalIds cde_enumerateObjectsDrainingEveryIterations:50 usingBlock:^(CDEGlobalIdentifier *globalId, NSUInteger index, BOOL *stop) {
            if ((id)globalId == [NSNull null]) {
                CDELog(CDELoggingLevelWarning, @"Tried to store updates for object with no global identifier. Skipping.");
                return;
            }
            
            NSURL *uri = [NSURL URLWithString:globalId.storeURI];
            NSManagedObjectID *objectID = [coordinator managedObjectIDForURIRepresentation:uri];
            NSArray *propertyChanges = [propertyChangeValuesByObjectID objectForKey:objectID];
            if (!propertyChanges) return;
            
            [self addObjectChangeOfType:CDEObjectChangeTypeUpdate forGlobalIdentifier:globalId entityName:objectID.entity.name propertyChanges:propertyChanges];
        }];
    }];
}

- (void)addChangesForUnsavedUpdatedObjects:(NSSet *)updatedObjects inManagedObjectContext:(NSManagedObjectContext *)context
{
    if (updatedObjects.count == 0) return;
    
    __block NSMutableDictionary *changedValuesByObjectID = nil;
    NSManagedObjectContext *updatedObjectsContext = context;
    [updatedObjectsContext performBlockAndWait:^{
        changedValuesByObjectID = [NSMutableDictionary dictionaryWithCapacity:updatedObjects.count];
        [updatedObjects.allObjects cde_enumerateObjectsDrainingEveryIterations:50 usingBlock:^(NSManagedObject *object, NSUInteger index, BOOL *stop) {
            NSArray *propertyChanges = [CDEPropertyChangeValue propertyChangesForObject:object propertyNames:object.changedValues.allKeys isPreSave:YES storeValues:YES];
            NSManagedObjectID *objectID = object.objectID;
            changedValuesByObjectID[objectID] = propertyChanges;
        }];
    }];
    
    [self addChangesForSavedUpdatedObjects:updatedObjects inManagedObjectContext:context propertyChangeValuesByObjectID:changedValuesByObjectID];
}

- (BOOL)addChangesForUnsavedManagedObjectContext:(NSManagedObjectContext *)contextWithChanges error:(NSError * __autoreleasing *)error
{
    __block BOOL success = NO;
    success = [contextWithChanges obtainPermanentIDsForObjects:contextWithChanges.insertedObjects.allObjects error:error];
    if (!success) return NO;

    [self addChangesForInsertedObjects:contextWithChanges.insertedObjects objectsAreSaved:NO inManagedObjectContext:contextWithChanges];
    [self addChangesForDeletedObjects:contextWithChanges.deletedObjects inManagedObjectContext:contextWithChanges];
    [self addChangesForUnsavedUpdatedObjects:contextWithChanges.updatedObjects inManagedObjectContext:contextWithChanges];
    
    [eventManagedObjectContext performBlockAndWait:^{
        success = [eventManagedObjectContext save:error];
    }];
    
    return success;
}

#pragma mark Converting property changes for storage in event store

- (void)addObjectChangeOfType:(CDEObjectChangeType)type forGlobalIdentifier:(CDEGlobalIdentifier *)globalId entityName:(NSString *)entityName propertyChanges:(NSArray *)propertyChanges
{
    NSParameterAssert(type == CDEObjectChangeTypeInsert || type == CDEObjectChangeTypeUpdate);
    NSParameterAssert(globalId != nil);
    NSParameterAssert(entityName != nil);
    NSParameterAssert(propertyChanges != nil);
    NSAssert(self.event, @"No event created. Call makeNewEvent first.");
    
    CDEObjectChange *objectChange = [NSEntityDescription insertNewObjectForEntityForName:@"CDEObjectChange" inManagedObjectContext:eventManagedObjectContext];
    objectChange.storeModificationEvent = self.event;
    objectChange.type = type;
    objectChange.nameOfEntity = entityName;
    objectChange.globalIdentifier = globalId;
    
    // Fetch the needed global ids 
    NSMutableSet *objectIDs = [[NSMutableSet alloc] initWithCapacity:propertyChanges.count];
    for (CDEPropertyChangeValue *propertyChange in propertyChanges) {
        if (propertyChange.relatedIdentifier) [objectIDs addObject:propertyChange.relatedIdentifier];
        if (propertyChange.addedIdentifiers) [objectIDs unionSet:propertyChange.addedIdentifiers];
        if (propertyChange.removedIdentifiers) [objectIDs unionSet:propertyChange.removedIdentifiers];
        if (propertyChange.movedIdentifiersByIndex) [objectIDs addObjectsFromArray:propertyChange.movedIdentifiersByIndex.allValues];
    }
    [objectIDs removeObject:[NSNull null]];
    NSArray *orderedObjectIDs = objectIDs.allObjects;
    NSArray *globalIds = [CDEGlobalIdentifier fetchGlobalIdentifiersForObjectIDs:orderedObjectIDs inManagedObjectContext:globalId.managedObjectContext];
    NSDictionary *globalIdentifiersByObjectID = [NSDictionary dictionaryWithObjects:globalIds forKeys:orderedObjectIDs];
    
    for (CDEPropertyChangeValue *propertyChange in propertyChanges) {
        [self convertRelationshipValuesToGlobalIdentifiersInPropertyChangeValue:propertyChange withGlobalIdentifiersByObjectID:globalIdentifiersByObjectID];
    }
    
    objectChange.propertyChangeValues = propertyChanges;
}

- (void)convertRelationshipValuesToGlobalIdentifiersInPropertyChangeValue:(CDEPropertyChangeValue *)propertyChange withGlobalIdentifiersByObjectID:(NSDictionary *)globalIdentifiersByObjectID
{
    switch (propertyChange.type) {
        case CDEPropertyChangeTypeToOneRelationship:
            [self convertToOneRelationshipValuesToGlobalIdentifiersInPropertyChangeValue:propertyChange withGlobalIdentifiersByObjectID:globalIdentifiersByObjectID];
            break;
            
        case CDEPropertyChangeTypeOrderedToManyRelationship:
        case CDEPropertyChangeTypeToManyRelationship:
            [self convertToManyRelationshipValuesToGlobalIdentifiersInPropertyChangeValue:propertyChange withGlobalIdentifiersByObjectID:globalIdentifiersByObjectID];
            break;
            
        case CDEPropertyChangeTypeAttribute:
        default:
            break;
    }
}

- (void)convertToOneRelationshipValuesToGlobalIdentifiersInPropertyChangeValue:(CDEPropertyChangeValue *)propertyChange withGlobalIdentifiersByObjectID:(NSDictionary *)globalIdentifiersByObjectID
{
    CDEGlobalIdentifier *globalId = nil;
    globalId = globalIdentifiersByObjectID[propertyChange.relatedIdentifier];
    if (propertyChange.relatedIdentifier && !globalId) {
        CDELog(CDELoggingLevelError, @"No global id found for to-one relationship with target objectID: %@", propertyChange.relatedIdentifier);
    }
    propertyChange.relatedIdentifier = globalId.globalIdentifier;
}

- (void)convertToManyRelationshipValuesToGlobalIdentifiersInPropertyChangeValue:(CDEPropertyChangeValue *)propertyChange withGlobalIdentifiersByObjectID:(NSDictionary *)globalIdentifiersByObjectID
{
    NSArray *addedGlobalIdentifiers = [globalIdentifiersByObjectID objectsForKeys:propertyChange.addedIdentifiers.allObjects notFoundMarker:[NSNull null]];
    NSArray *removedGlobalIdentifiers = [globalIdentifiersByObjectID objectsForKeys:propertyChange.removedIdentifiers.allObjects notFoundMarker:[NSNull null]];
    
    BOOL foundAllAddedIds = ![addedGlobalIdentifiers containsObject:[NSNull null]];
    BOOL foundAllRemovedIds = ![removedGlobalIdentifiers containsObject:[NSNull null]];
    if (!foundAllAddedIds) {
        CDELog(CDELoggingLevelError, @"Missing global ids for added ids in a to-many relationship. Target objectIDs: %@ %@", propertyChange.addedIdentifiers, addedGlobalIdentifiers);
    }
    if (!foundAllRemovedIds) {
        CDELog(CDELoggingLevelError, @"Missing global ids for removed ids in a to-many relationship. Target objectIDs with global ids: %@ %@", propertyChange.removedIdentifiers, removedGlobalIdentifiers);
    }
    
    propertyChange.addedIdentifiers = [NSSet setWithArray:[addedGlobalIdentifiers valueForKeyPath:@"globalIdentifier"]];
    propertyChange.removedIdentifiers = [NSSet setWithArray:[removedGlobalIdentifiers valueForKeyPath:@"globalIdentifier"]];
    
    if (propertyChange.type != CDEPropertyChangeTypeOrderedToManyRelationship) return;
    
    NSMutableDictionary *newMovedIdentifiers = [[NSMutableDictionary alloc] initWithCapacity:propertyChange.movedIdentifiersByIndex.count];
    for (NSNumber *index in propertyChange.movedIdentifiersByIndex.allKeys) {
        id objectID = propertyChange.movedIdentifiersByIndex[index];
        id globalIdentifier = [[globalIdentifiersByObjectID objectForKey:objectID] globalIdentifier];
        newMovedIdentifiers[index] = globalIdentifier;
    }
    propertyChange.movedIdentifiersByIndex = newMovedIdentifiers;
}

@end
