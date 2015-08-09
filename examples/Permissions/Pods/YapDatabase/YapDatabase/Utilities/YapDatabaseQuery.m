#import "YapDatabaseQuery.h"
#import "YapDatabaseLogging.h"

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

/**
 * Define log level for this file: OFF, ERROR, WARN, INFO, VERBOSE
 * See YapDatabaseLogging.h for more information.
**/
#if DEBUG
  static const int ydbLogLevel = YDB_LOG_LEVEL_WARN;
#else
  static const int ydbLogLevel = YDB_LOG_LEVEL_WARN;
#endif
#pragma unused(ydbLogLevel)


/**
 * A YapDatabaseQuery is used to pass SQL style queries into various extension classes.
 * The query that you pass represents everything after the SELECT clause of a query.
 *
 * For example:
 * query = [YapDatabaseQuery queryWithFormat:@"WHERE department = ? AND salary >= ?", deptStr, @(minSalary)];
 * [secondaryIndex enumerateKeysAndObjectsMatchingQuery:query
 *                                           usingBlock:^(NSString *collection, NSString *key, id object, BOOL *stop){
 *     ...
 * }];
 *
 * Methods that take YapDatabaseQuery parameters will automatically prefix your query string with
 * the proper 'SELECT' clause. So it may get expanded to something like this:
 *
 * @"SELECT rowid FROM 'database' WHERE department = ? AND salary >= ?"
 *
 * YapDatabaseQuery supports the following types as query parameters:
 * - NSNumber
 * - NSDate    (automatically converted to double via timeIntervalSinceReferenceDate)
 * - NSString
 * - NSArray   (of any regular type above)
 *
 * Example 2:
 *
 * NSArray *departments = [self engineeringDepartments];
 * query = [YapDatabaseQuery queryWithFormat:@"WHERE title = ? AND department IN (?)", @"manager", departments];
**/
@implementation YapDatabaseQuery
{
	NSString *queryString;
	NSArray *queryParameters;
}

/**
 * A YapDatabaseQuery is everything after the SELECT clause of a query.
 * Thus they generally start with "WHERE ...".
 *
 * Please note that you can ONLY pass objects as parameters.
 * Primitive types such as int, float, double, etc are NOT supported.
 * You MUST wrap these using NSNumber.
**/
+ (instancetype)queryWithFormat:(NSString *)format, ...
{
    va_list arguments;
    va_start(arguments, format);
    id query = [self queryWithFormat:format arguments:arguments];
    va_end(arguments);
    return query;
}

/**
 * Alternative initializer if you have a prepared va_list.
 *
 * Swift note:
 * You may prefer to use 'queryWithString:(NSString *)queryString parameters:(NSArray *)queryParameters' instead.
 *
 * Alternatively, define the following somewhere in your Swift code:
 *
 * extension YapDatabaseQuery {
 *     class func queryWithFormat(format: String, _ arguments: CVarArgType...) -> YapDatabaseQuery? {
 *         return withVaList(arguments, { YapDatabaseQuery(format: format, arguments: $0) })
 *     }
 * }
**/
+ (instancetype)queryWithFormat:(NSString *)format arguments:(va_list)args
{
	if (format == nil) return nil;
	
	NSArray *paramLocations = [self findParamLocations:format];
	NSUInteger paramCount = [paramLocations count];
	
	NSMutableArray *queryParameters = [NSMutableArray arrayWithCapacity:paramCount];
	
	@try
	{
		for (NSUInteger i = 0; i < paramCount; i++)
		{
			id param = va_arg(args, id);
			
			// Please note that you can ONLY pass proper objects as parameters.
			// Primitive types such as int, float, double, etc are NOT supported.
			// You MUST wrap these using NSNumber.
			//
			[queryParameters addObject:param];
		}
	}
	@catch (NSException *exception)
	{
		YDBLogError(@"Error processing query. Expected %lu parameters. All parameters must be objects. %@",
		            (unsigned long)paramCount, exception);
		
		queryParameters = nil;
	}
	
	return [self queryWithString:format parameters:queryParameters paramLocations:paramLocations];
}

/**
 * Alternative initializer - generally preferred for Swift code.
**/
+ (instancetype)queryWithString:(NSString *)queryString parameters:(NSArray *)queryParameters
{
	if (queryString == nil) return nil;
	
	return [self queryWithString:queryString parameters:queryParameters paramLocations:nil];
}

/**
 * Private API - handles expanding arrays in the given queryParameters
**/
+ (instancetype)queryWithString:(NSString *)inQueryString
                     parameters:(NSArray *)inQueryParameters
                 paramLocations:(NSArray *)inParamLocations
{
	NSParameterAssert(inQueryString != nil);
	
	NSMutableArray *queryParameters = [NSMutableArray arrayWithCapacity:[inQueryParameters count]];
	
	// Look for arrays in the 'queryParameters' parameter
	
	NSMutableDictionary *paramIndexToArrayCountMap = [NSMutableDictionary dictionary];
	
	[inQueryParameters enumerateObjectsUsingBlock:^(id param, NSUInteger paramIndex, BOOL *stop) {
		
		if ([param isKindOfClass:[NSArray class]])
		{
			NSUInteger arrayCount = [param count];
			if (arrayCount == 0)
			{
				[queryParameters addObject:[NSNull null]];
			}
			else
			{
				paramIndexToArrayCountMap[@(paramIndex)] = @([param count]);
				[queryParameters addObjectsFromArray:param];
			}
		}
		else
		{
			[queryParameters addObject:param];
		}
	}];
	
	// Unpack the array(s) if needed
	
	if (paramIndexToArrayCountMap.count > 0)
	{
		NSMutableString *queryString = [inQueryString mutableCopy];
		
		NSArray *paramLocations = inParamLocations ?: [self findParamLocations:queryString];
		
		// Expand the array's in the queryParameter list.
		//
		// For example:
		// - inQueryString : @"col1 = ? AND col2 in (?)"
		// - inQueryParams : @[ @(0), @[ @(1), @(2) ] ]
		//
		// - outQueryString: @"col1 = ? AND col2 in (?,?)"
		// - outQueryParmas: @[ @(0), @(1), @(2) ]
		
		__block NSUInteger unpackingOffset = 0;
			
		[paramIndexToArrayCountMap enumerateKeysAndObjectsUsingBlock:
		    ^(NSNumber *paramIndexNum, NSNumber *arrayCountNum, BOOL *stop)
		{
			NSUInteger arrayCount = [arrayCountNum unsignedIntegerValue];
			
			NSMutableString *unpackedParamsStr = [NSMutableString stringWithCapacity:(arrayCount * 2)];
			for (NSUInteger i = 0; i < arrayCount; i++)
			{
				if (i == 0)
					[unpackedParamsStr appendString:@"?"];
				else
					[unpackedParamsStr appendString:@",?"];
			}
			
			NSUInteger paramIndex = [paramIndexNum unsignedIntegerValue];
			NSUInteger paramLocation = [paramLocations[paramIndex] unsignedIntegerValue];
			
			NSRange range = NSMakeRange(paramLocation + unpackingOffset, 1);
			unpackingOffset += [unpackedParamsStr length] - 1;
			
			[queryString replaceCharactersInRange:range withString:unpackedParamsStr];
			
		}];
		
		return [[YapDatabaseQuery alloc] initWithQueryString:queryString queryParameters:queryParameters];
	}
	else
	{
		return [[YapDatabaseQuery alloc] initWithQueryString:inQueryString queryParameters:queryParameters];
	}
}

/**
 * Shorthand for a query with no 'WHERE' clause.
 * Equivalent to [YapDatabaseQuery queryWithFormat:@""].
 **/
+ (instancetype)queryMatchingAll
{
	return [[YapDatabaseQuery alloc] initWithQueryString:@"" queryParameters:nil];
}

/**
 * Utility method to find all the '?' locations in a queryString.
**/
+ (NSArray *)findParamLocations:(NSString *)queryString
{
	NSMutableArray *paramLocations = [NSMutableArray array];
	
	NSUInteger paramCount = 0;
	NSUInteger queryStringLength = [queryString length];
	
	NSRange searchRange = NSMakeRange(0, queryStringLength);
	NSRange paramRange = [queryString rangeOfString:@"?" options:0 range:searchRange];
	
	while (paramRange.location != NSNotFound)
	{
		paramCount++;
		
		[paramLocations addObject:@(paramRange.location)];
		
		searchRange.location = paramRange.location + 1;
		searchRange.length = queryStringLength - searchRange.location;
		
		paramRange = [queryString rangeOfString:@"?" options:0 range:searchRange];
	}
	
	return paramLocations;
}

- (id)initWithQueryString:(NSString *)inQueryString queryParameters:(NSArray *)inQueryParameters
{
	if ((self = [super init]))
	{
		queryString = [inQueryString copy];
		queryParameters = [inQueryParameters copy];
	}
	return self;
}

@synthesize queryString;
@synthesize queryParameters;

@end