//
//  SUSecureCoding.m
//  Sparkle
//
//  Created by Mayur Pawashe on 3/24/16.
//  Copyright © 2016 Sparkle Project. All rights reserved.
//

#import "SUSecureCoding.h"
#import "SULog.h"

static NSString *SURootObjectArchiveKey = @"SURootObjectArchive";

NSData * _Nullable SUArchiveRootObjectSecurely(id<NSSecureCoding> rootObject)
{
    NSMutableData *data = [NSMutableData data];
    NSKeyedArchiver *keyedArchiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
    keyedArchiver.requiresSecureCoding = YES;
    
    @try {
        [keyedArchiver encodeObject:rootObject forKey:SURootObjectArchiveKey];
        [keyedArchiver finishEncoding];
        return [data copy];
    } @catch (NSException *exception) {
        SULog(@"Exception while securely archiving object: %@", exception);
        [keyedArchiver finishEncoding];
        return nil;
    }
}

id<NSSecureCoding> _Nullable SUUnarchiveRootObjectSecurely(NSData *data, Class klass)
{
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:data];
    unarchiver.requiresSecureCoding = YES;
    
    @try {
        id<NSSecureCoding> rootObject = [unarchiver decodeObjectOfClass:klass forKey:SURootObjectArchiveKey];
        [unarchiver finishDecoding];
        return rootObject;
    } @catch (NSException *exception) {
        SULog(@"Exception while securely unarchiving object: %@", exception);
        [unarchiver finishDecoding];
        return nil;
    }
}
